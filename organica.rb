# encoding: UTF-8
# PCF Ferramentas - Recorte orgânico
# Seleciona a modelagem (peça desenhada na espessura do MDF) e o botão cria sozinho
# o tamponamento Dinabox com o recorte, igual a fazer com a fresa do Dinabox:
#   tamponamento = peça + sobra (10 mm) de cada lado, mesma espessura
#   contorno da peça = corte POR FORA; furos internos = corte POR DENTRO
#   profundidade = espessura cheia + 0,05 (18,3 -> 18,05)
# O tamponamento vai para acima do teto, na mesma posição da modelagem (a modelagem fica onde está).
require 'json'

module PCF
  module Ferramentas
    CAMADA_CONTORNO = 'DB Contorno'.freeze unless defined?(CAMADA_CONTORNO)
    MODELO_TAMP = File.join(DIR, 'modelos', 'tamponamento_dinabox.skp') unless defined?(MODELO_TAMP)

    class << self
      def tamponamento?(e)
        return false unless e.respond_to?(:definition)
        e.definition.get_attribute(DA, 'dinabox_submodel') == 'tamponamento' ||
          e.get_attribute(DA, 'dinabox_submodel') == 'tamponamento'
      end

      # um tamponamento Dinabox para servir de molde (do modelo aberto ou o salvo pelo PCF)
      def molde_tamponamento
        m = model
        inst = nil
        m.definitions.each do |d|
          next if d.image?
          next unless d.get_attribute(DA, 'dinabox_submodel') == 'tamponamento'
          inst = d.instances.find(&:valid?)
          break if inst
        end
        if inst
          salvar_molde(inst.definition)
          return [inst.definition, inst]
        end
        return [m.definitions.load(MODELO_TAMP), nil] if File.exist?(MODELO_TAMP)
        nil
      end

      def salvar_molde(defn)
        return if File.exist?(MODELO_TAMP)
        Dir.mkdir(File.dirname(MODELO_TAMP)) unless Dir.exist?(File.dirname(MODELO_TAMP))
        defn.save_as(MODELO_TAMP)
      rescue StandardError => ex
        puts "PCF molde: #{ex.message}"
      end

      # faces da modelagem em coordenadas do mundo: [[face, transformação], ...]
      def faces_mundo(ents, tr, out = [], nivel = 0)
        ents.each do |x|
          if x.is_a?(Sketchup::Face)
            out << [x, tr]
          elsif (x.is_a?(Sketchup::Group) || x.is_a?(Sketchup::ComponentInstance)) && nivel < 4
            faces_mundo(x.definition.entities, tr * x.transformation, out, nivel + 1)
          end
        end
        out
      end

      # lote = true: chamado pelo recorte em grupo (sem operação própria, erro sobe para quem chamou)
      def recorte_organico(h = {}, alvo = nil, tr_pai = nil, lote = false)
        falha = ->(t) { lote ? raise(t) : aviso(t) }
        # botão da barra / menu (criados antes da atualização) chamam este método: sem peça definida, faz toda a seleção
        return recorte_organico_selecao(h) if alvo.nil? && !lote
        sobra = (calc(h['sobra'].to_s) || 10.0).mm
        diam = (calc(h['di'].to_s) || 6.1)
        sel = model.selection.to_a
        mod = alvo || sel.find { |e| (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) && !dinabox?(e) }
        return falha.('Selecione a MODELAGEM da peça (grupo ou componente desenhado na espessura do MDF).') unless mod
        molde = molde_tamponamento
        return falha.('Não achei um tamponamento Dinabox para usar de molde. Coloque 1 tamponamento no projeto e tente de novo.') unless molde
        tw = edit_t * (tr_pai || Geom::Transformation.new) * mod.transformation
        fs = faces_mundo(mod.definition.entities, tw)
        return falha.('A modelagem não tem faces.') if fs.empty?
        face, ftr = fs.max_by { |f, t| f.area(t) }
        n = face.normal.transform(ftr)
        n.normalize!
        # eixos no plano da peça: os eixos da própria modelagem que ficam deitados no plano
        eixos = [tw.xaxis, tw.yaxis, tw.zaxis].map { |v| v = v.clone; v.normalize!; v }
        noplano = eixos.sort_by { |v| (v % n).abs }.first(2)
        if n.z.abs < 0.7 # peça em pé: altura = eixo mais vertical
          ey = noplano.max_by { |v| v.z.abs }
          ex = noplano.find { |v| !v.equal?(ey) }
          ey = ey.reverse if ey.z < 0
        else
          ex, ey = noplano
        end
        ez = ex * ey
        ez.normalize!
        # espessura = espessura da modelagem na direção da normal
        pts_todos = fs.flat_map { |f, t| f.vertices.map { |vx| vx.position.transform(t) } }
        o0 = pts_todos.first
        proj = ->(p, v) { (p - o0) % v }
        zs = pts_todos.map { |p| proj.call(p, ez) }
        esp = zs.max - zs.min
        return falha.('Não consegui medir a espessura da modelagem.') if esp < 1.mm
        # contorno (laço externo) e furos (laços internos) da maior face
        laco = ->(l) { l.vertices.map { |vx| p = vx.position.transform(ftr); [proj.call(p, ex), proj.call(p, ey)] } }
        externo = laco.call(face.outer_loop)
        furos = face.loops.reject(&:outer?).map { |l| laco.call(l) }
        # rebaixos / canais que não vazam: faces paralelas à peça no meio da espessura (fundo do rebaixo)
        tol = 0.05.mm
        rebaixos = []
        fs.each do |f, t|
          nf = f.normal.transform(t); nf.normalize!
          next unless (nf % ez).abs > 0.999
          zc = proj.call(f.vertices.first.position.transform(t), ez)
          next if zc < zs.min + tol || zc > zs.max - tol
          cima = (nf % ez) > 0
          prof = cima ? zs.max - zc : zc - zs.min
          pts = f.outer_loop.vertices.map { |vx| q = vx.position.transform(t); [proj.call(q, ex), proj.call(q, ey)] }
          rebaixos << [pts, prof.to_mm.round(2), cima]
        end
        us = externo.map(&:first); vs = externo.map(&:last)
        umin = us.min; vmin = vs.min
        larg = us.max - umin + 2 * sobra
        alt = vs.max - vmin + 2 * sobra
        esp_mm = esp.to_mm.round(2)
        pz = (esp_mm.floor + 0.05).round(2)
        origem = o0.offset(ex, umin - sobra).offset(ey, vmin - sobra).offset(ez, zs.min)

        defn, inst_molde = molde
        m = model
        m.start_operation('Recorte orgânico', true) unless lote
        aberta = !lote
        tamp = m.active_entities.add_instance(defn, edit_t.inverse * Geom::Transformation.axes(origem, ex, ey, ez))
        copiar_atributos(inst_molde, tamp) if inst_molde
        tamp.make_unique
        painel = tamp.definition.entities.grep(Sketchup::ComponentInstance).find { |c| c.definition.entities.grep(Sketchup::ComponentInstance).any? || c.get_attribute(DA, 'lenx') } ||
                 tamp.definition.entities.grep(Sketchup::ComponentInstance).first
        painel.make_unique if painel
        tamp.set_attribute(DA, '_lenx_formula', (larg.to_mm / 10.0).round(2).to_s)
        tamp.set_attribute(DA, '_leny_formula', (alt.to_mm / 10.0).round(2).to_s)
        tamp.set_attribute(DA, 'espessura', (esp_mm / 10.0).round(3).to_s)
        tamp.set_attribute(DA, '_espessura_formula', (esp_mm / 10.0).round(3).to_s)
        redraw(tamp)
        painel = tamp.definition.entities.grep(Sketchup::ComponentInstance).first
        raise 'o tamponamento ficou sem painel' unless painel
        painel.make_unique if painel.definition.count_instances > 1
        # limpa recortes que vieram do molde
        velhos = painel.definition.entities.grep(Sketchup::ComponentInstance).select { |c| c.definition.name =~ /dinabox_polyline/i }
        painel.definition.entities.erase_entities(velhos) unless velhos.empty?
        # escala do painel = tamanho final / tamanho do molde do painel (não depende de quando o Dinabox redesenha)
        pb = painel.definition.bounds
        sx = larg / pb.width; sy = alt / pb.height; sz = esp / pb.depth
        camada = m.layers[CAMADA_CONTORNO] || m.layers.add(CAMADA_CONTORNO)
        # posições no painel: (u, v) a partir do canto do tamponamento (já com a sobra)
        rel = ->(l) { l.map { |u, v| [u - umin + sobra, v - vmin + sobra] } }
        # a linha do Dinabox é o caminho do CENTRO da fresa: contorno meia fresa para fora, furos meia fresa para dentro
        raio = (diam / 2.0).mm
        add_poly(painel, offset_poligono(rel.call(externo), raio), '1', diam, pz, sx, sy, sz, camada)
        furos.each { |f| add_poly(painel, offset_poligono(rel.call(f), -raio), '2', diam, pz, sx, sy, sz, camada) }
        # rebaixo: caminho do centro da fresa por dentro; canal que chega na borda passa para fora da peça
        rebaixos.each do |pts, prof, cima|
          caminho = caminho_rebaixo(rel.call(pts), raio, [sobra, sobra, larg - sobra, alt - sobra])
          add_poly(painel, caminho, '2', diam, prof, sx, sy, sz, camada, cima ? pb.depth : 0)
        end
        painel.set_attribute('dinabox', 'polyline', true)
        tamp.set_attribute('dinabox', 'polyline', true)
        # acima do teto, na mesma posição da modelagem
        bb = tamp.bounds
        # 5000 mm acima da modelagem (mesma posição em planta), para não ficar na frente dos móveis
        tamp.transform!(Geom::Transformation.translation([0, 0, 5000.mm]))
        tamp.name = mod.name unless mod.name.to_s.strip.empty? # leva o nome (ex.: Moldura - Porta Esquerda - Armário) para o plano
        # marca a modelagem: o PCF Label corta o tamponamento e não a modelagem (enquanto o tamponamento existir)
        mod.set_attribute('pcf', 'virou', tamp.persistent_id.to_s) rescue nil
        # linha de corte final (contorno real da peça) desenhada 0,5 mm na frente da face do painel
        wpa = edit_t * tamp.transformation * painel.transformation
        para_mundo = ->(l) { l.map { |u, v| Geom::Point3d.new(u / sx, v / sy, 0).transform(wpa) } }
        desenhar_linha_corte(tamp.name.to_s.empty? ? 'recorte orgânico' : tamp.name, [para_mundo.call(rel.call(externo))] + furos.map { |f| para_mundo.call(rel.call(f)) } + rebaixos.map { |pts, _, _| para_mundo.call(rel.call(pts)) }, painel, wpa)
        return tamp if lote
        m.commit_operation
        m.selection.clear
        m.selection.add(tamp)
        mudou
        aviso("Recorte orgânico criado: tamponamento #{larg.to_mm.round} × #{alt.to_mm.round} × #{esp_mm} mm, " \
              "contorno por fora#{furos.empty? ? '' : " + #{furos.size} furo(s) por dentro"}#{rebaixos.empty? ? '' : " + #{rebaixos.size} rebaixo(s) (#{rebaixos.map { |_, pr, _| pr }.uniq.join('/')} mm)"}, profundidade #{pz}. Está acima do teto.")
      rescue StandardError => ex
        raise if lote
        m.abort_operation if aberta
        aviso("Erro no recorte orgânico: #{ex.message}")
        puts ex.backtrace.first(5)
      end

      # peças (modelagens) dentro da seleção: entra nos grupos até achar quem tem as faces
      def pecas_organicas(ents, tr, out = [], nivel = 0, pai = '')
        ents.each do |e|
          next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          next if dinabox?(e) || tamponamento?(e) || e.get_attribute('pcf', 'tipo') == 'linha_corte' || e.hidden? || !e.layer.visible?
          filhos = e.definition.entities.select { |x| (x.is_a?(Sketchup::Group) || x.is_a?(Sketchup::ComponentInstance)) && !x.hidden? }
          tem_faces = e.definition.entities.any? { |x| x.is_a?(Sketchup::Face) }
          if filhos.empty? || nivel >= 5
            out << [e, tr, pai] if tem_faces || !filhos.empty?
          else
            antes = out.size
            pecas_organicas(filhos, tr * e.transformation, out, nivel + 1, e.name.to_s.strip.empty? ? pai : e.name.to_s.strip)
            out << [e, tr, pai] if out.size == antes && tem_faces # grupo só com faces soltas
          end
        end
        out
      end

      # recorte de tudo o que estiver selecionado (também peças dentro de grupos)
      def recorte_organico_selecao(h = {})
        m = model
        alvos = pecas_organicas(m.selection.to_a, Geom::Transformation.new)
        return aviso('Selecione a MODELAGEM da peça (ou um grupo com várias peças).') if alvos.empty?
        return recorte_organico(h, alvos[0][0], alvos[0][1]) if alvos.size == 1
        criados = []
        erros = []
        m.start_operation('Recorte orgânico (vários)', true)
        alvos.each_with_index do |(e, tr, pai), i|
          begin
            t = recorte_organico(h, e, tr, true)
            next unless t
            if t.name.to_s.strip.empty? # peça sem nome dentro de grupo: leva o nome do grupo
              t.name = pai.to_s.empty? ? "Orgânico #{i + 1}" : "#{pai} - peça #{i + 1}"
            end
            criados << t
          rescue StandardError => ex
            erros << "#{e.name.to_s.empty? ? e.definition.name : e.name}: #{ex.message}"
          end
        end
        m.commit_operation
        m.selection.clear
        m.selection.add(criados.select(&:valid?))
        mudou
        msg = "Recorte orgânico: #{criados.size} de #{alvos.size} peça(s) criadas acima do teto."
        msg += " Não deu em #{erros.size}: #{erros.first(3).join(' | ')}" unless erros.empty?
        aviso(msg)
      rescue StandardError => ex
        m.abort_operation
        aviso("Erro no recorte orgânico: #{ex.message}")
      end

      def copiar_atributos(de, para)
        (de.attribute_dictionaries || []).each do |d|
          next unless [DA, 'dinabox'].include?(d.name)
          d.each_pair do |k, v|
            next if d.name == 'dinabox' && %w[persistent_id seq_id].include?(k)
            para.set_attribute(d.name, k, v)
          end
        end
        para.material = de.material if de.material
      end

      # desenha a linha de corte final (só para conferir; não é usinagem) num grupo na etiqueta "PCF Linha de corte"
      # dentro = peça onde a linha fica guardada (apagou/moveu a peça, a linha vai junto)
      # tr_dentro = transformação até o mundo de "dentro" (quando está aninhado).
      # IMPORTANTE: guardar dentro da CHAPA (painel), nunca solta no tamponamento/módulo — o Dinabox
      # usa os grupos do tamponamento para medir e esticava o recorte (bug da 1.4.2).
      def desenhar_linha_corte(nome, lacos_mundo, dentro = nil, tr_dentro = nil)
        m = model
        tag = m.layers['PCF Linha de corte'] || m.layers.add('PCF Linha de corte')
        tag.color = Sketchup::Color.new(220, 30, 30) rescue nil
        if dentro
          g = dentro.definition.entities.add_group
          it = (tr_dentro || (edit_t * dentro.transformation)).inverse
        else
          g = m.active_entities.add_group
          it = edit_t.inverse
        end
        lacos_mundo.each do |pts|
          next if pts.size < 2
          lp = pts.map { |p| p.transform(it) }
          lp << lp.first
          g.entities.add_edges(lp)
        end
        g.name = "Linha de corte - #{nome}"
        g.layer = tag
        g.set_attribute('pcf', 'tipo', 'linha_corte')
        g.locked = true
        g
      end

      # afasta um contorno fechado [[u,v],...]: d > 0 aumenta (para fora), d < 0 diminui (para dentro)
      def offset_poligono(pts, d)
        ps = []
        pts.each { |p| ps << p unless ps.last && (ps.last[0] - p[0]).abs < 1e-6 && (ps.last[1] - p[1]).abs < 1e-6 }
        ps.pop if ps.size > 1 && (ps.first[0] - ps.last[0]).abs < 1e-6 && (ps.first[1] - ps.last[1]).abs < 1e-6
        n = ps.size
        return ps if n < 3 || d.zero?
        area = 0.0
        ps.each_with_index { |a, i| b = ps[(i + 1) % n]; area += a[0] * b[1] - b[0] * a[1] }
        anti = area > 0
        normal = lambda do |a, b|
          dx = b[0] - a[0]; dy = b[1] - a[1]
          l = Math.sqrt(dx * dx + dy * dy)
          l = 1e-12 if l < 1e-12
          anti ? [dy / l, -dx / l] : [-dy / l, dx / l] # aponta para fora da área
        end
        ps.each_index.map do |i|
          a = ps[i - 1]; b = ps[i]; c = ps[(i + 1) % n]
          n1 = normal.call(a, b); n2 = normal.call(b, c)
          bx = n1[0] + n2[0]; by = n1[1] + n2[1]
          l = Math.sqrt(bx * bx + by * by)
          if l < 1e-9
            bx, by = n1; esc = 1.0
          else
            bx /= l; by /= l
            cosv = bx * n1[0] + by * n1[1]
            esc = cosv > 0.25 ? 1.0 / cosv : 4.0
          end
          [b[0] + bx * d * esc, b[1] + by * d * esc]
        end
      end

      # uma polilinha de recorte do Dinabox (laço fechado), com a escala do painel compensada
      # caminho do centro da fresa num rebaixo: retângulo deitado nos eixos = encolhe meia fresa (canal estreito vira uma passada no meio)
      # e o lado que encosta na borda da peça passa meia fresa + 1 mm para fora (canal aberto); outro formato = offset por dentro
      def caminho_rebaixo(pts, raio, caixa)
        tol = 0.05.mm
        us = pts.map(&:first); vs = pts.map(&:last)
        u0, u1, v0, v1 = us.min, us.max, vs.min, vs.max
        reto = pts.uniq.size == 4 && pts.all? { |u, v| ((u - u0).abs < tol || (u - u1).abs < tol) && ((v - v0).abs < tol || (v - v1).abs < tol) }
        return offset_poligono(pts, -raio) unless reto
        cu = (u0 + u1) / 2.0; cv = (v0 + v1) / 2.0
        hu = [(u1 - u0) / 2.0 - raio, 0.05.mm].max; hv = [(v1 - v0) / 2.0 - raio, 0.05.mm].max
        a0 = cu - hu; a1 = cu + hu; b0 = cv - hv; b1 = cv + hv
        fora = raio + 1.mm
        a0 = caixa[0] - fora if (u0 - caixa[0]).abs < tol
        a1 = caixa[2] + fora if (u1 - caixa[2]).abs < tol
        b0 = caixa[1] - fora if (v0 - caixa[1]).abs < tol
        b1 = caixa[3] + fora if (v1 - caixa[3]).abs < tol
        [[a0, b0], [a1, b0], [a1, b1], [a0, b1]]
      end

      def add_poly(painel, pts, align, diam, pz, sx, sy, sz, camada, z = 0)
        return if pts.size < 3
        ou = pts.map(&:first).min
        ov = pts.map(&:last).min
        d = model.definitions.add('dinabox_polyline')
        loc = pts.map { |u, v| Geom::Point3d.new(u - ou, v - ov, 0) }
        loc << loc.first unless loc.first == loc.last
        d.entities.add_edges(loc)
        dados = JSON.generate('align' => align, 'di' => diam.to_s, 'pz' => pz.to_s, 'co' => '', 've' => '', 'r1' => '', 'et' => '1')
        d.set_attribute('dinabox', 'polyline', dados)
        tr = Geom::Transformation.translation([ou / sx, ov / sy, z]) * Geom::Transformation.scaling(1.0 / sx, 1.0 / sy, 1.0 / sz)
        i = painel.definition.entities.add_instance(d, tr)
        i.layer = camada
        i.set_attribute('dinabox', 'polyline', dados)
        i
      end
    end
  end
end
