# PCF Label - Detalhamento: uma folha por MÓDULO Dinabox
#   vista de frente SEM PORTAS (mostra o miolo) com as cotas dos vãos: altura de cada vão por coluna,
#   largura de cada vão por faixa, largura e altura totais · ao lado, o 3D do módulo com as portas.
#   As cenas são "PCF M01 ..." (o módulo sozinho, o resto escondido só na cena).
module PCFLabel
  module Detalhar
    DA_DB = 'dynamic_attributes'.freeze
    NAO_MODULO = %w[tamponamento acessorio interno conteiner].freeze

    def self.submodelo(e)
      (e.get_attribute(DA_DB, 'dinabox_submodel') || e.definition.get_attribute(DA_DB, 'dinabox_submodel')).to_s
    end
    def self.porta?(e) e.definition.name =~ /dinabox_porta|cont_porta|puxador/i end
    def self.bb_mundo(b, t) bb = Geom::BoundingBox.new; 8.times { |k| bb.add(b.corner(k).transform(t)) }; bb end

    # módulos Dinabox visíveis (só o de fora; os internos ficam dentro dele)
    def self.modulos(m)
      out = []
      busca = lambda do |ents, t, cam, d|
        ents.each do |e|
          next unless (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) && e.visible? && (e.layer.visible? rescue true)
          sm = submodelo(e); tw = t * e.transformation
          if !sm.empty? && !NAO_MODULO.include?(sm)
            bb = bb_mundo(e.definition.bounds, tw)
            out << { inst: e, t: tw, sm: sm, bb: bb, cam: cam + [e] } if [bb.width, bb.height, bb.depth].min > 150.mm
          elsif sm.empty? && d < 3
            busca.(e.definition.entities, tw, cam + [e], d + 1)
          end
        end
      end
      busca.(m.entities, Geom::Transformation.new, [], 0)
      out.sort_by { |md| [md[:bb].min.x.to_f.round(-2), md[:bb].min.y.to_f.round(-2)] }.first(30)
    end

    # peças do módulo (mundo) e portas
    def self.pecas_modulo(md)
      pecas = []; portas = []
      anda = lambda do |e, t, dentro_gaveta|
        e.definition.entities.each do |c|
          next unless (c.is_a?(Sketchup::Group) || c.is_a?(Sketchup::ComponentInstance)) && c.visible?
          tc = t * c.transformation
          if porta?(c) then portas << [c, tc]; next end
          nome = c.definition.name
          gav = dentro_gaveta || nome =~ /conteiner_gaveta|dinabox_gaveta/i
          if nome =~ /dinabox_peca_/i && !gav
            pecas << { inst: c, bb: bb_mundo(c.definition.bounds, tc) }
          else
            anda.(c, tc, gav)
          end
        end
      end
      anda.(md[:inst], md[:t], false)
      [pecas, portas]
    end

    # direção da FRENTE do módulo (para onde as portas olham)
    def self.frente(md, portas)
      ce = md[:bb].center
      if portas.any?
        bp = Geom::BoundingBox.new; portas.each { |p, t| bp.add(bb_mundo(p.definition.bounds, t)) }
        v = bp.center - ce; v.z = 0
        return v.normalize if v.length > 1.mm
      end
      [md[:t].zaxis, md[:t].xaxis, md[:t].yaxis].map { |a| Geom::Vector3d.new(a.x, a.y, 0) }.max_by(&:length).normalize
    end

    # base da vista: u = para a direita de quem olha, v = altura, w = frente
    def self.base_vista(fr) u = fr.reverse * Z_AXIS; u.normalize!; [u, Z_AXIS, fr] end
    def self.faixa(bb, eixo) (0..7).map { |k| (bb.corner(k) - ORIGIN) % eixo }.minmax end
    def self.pt3(u, v, w, b) ORIGIN.offset(b[0], u).offset(b[1], v).offset(b[2], w) end

    # vãos: alturas por coluna e larguras por faixa (medidas internas, só o que vale a pena cotar)
    def self.vaos(pecas, b)
      cx = pecas.map do |p|
        u0, u1 = faixa(p[:bb], b[0]); v0, v1 = faixa(p[:bb], b[1]); w0, w1 = faixa(p[:bb], b[2])
        { u0: u0, u1: u1, v0: v0, v1: v1, du: u1 - u0, dv: v1 - v0, dw: w1 - w0 }
      end
      fino = 40.mm; grande = 100.mm; gap_min = 30.mm
      vert = cx.select { |p| p[:du] <= fino && p[:dv] >= grande && p[:dw] >= grande }
      hori = cx.select { |p| p[:dv] <= fino && p[:du] >= grande && p[:dw] >= grande }
      col = []
      vs = vert.sort_by { |p| (p[:u0] + p[:u1]) / 2 }
      vs.each_cons(2) { |a, c| col << (a[:u1] + c[:u0]) / 2 if c[:u0] - a[:u1] > 80.mm }
      alturas = []
      col.first(8).each do |uc|
        hs = hori.select { |h| h[:u0] - 1.mm <= uc && h[:u1] + 1.mm >= uc }.sort_by { |h| h[:v0] }
        hs.each_cons(2) { |a, c| alturas << [uc, a[:v1], c[:v0]] if c[:v0] - a[:v1] > gap_min }
      end
      niveis = hori.map { |h| [h[:v0], h[:v1]] }.sort.uniq { |a| (a[0] / 5.mm).round }
      larguras = []; vistos = []
      niveis.each_cons(2) do |a, c|
        vc = (a[1] + c[0]) / 2; next if c[0] - a[1] < gap_min
        us = vert.select { |p| p[:v0] - 1.mm <= vc && p[:v1] + 1.mm >= vc }.sort_by { |p| p[:u0] }
        ch = []; us.each_cons(2) { |p, q| ch << [p[:u1], q[:u0]] if q[:u0] - p[:u1] > gap_min }
        k = ch.map { |x0, x1| [(x0 / 1.mm).round, (x1 / 1.mm).round] }
        next if ch.empty? || vistos.include?(k)
        vistos << k; larguras << [vc, ch]
      end
      [alturas, larguras.first(6), cx]
    end

    def self.nome_modulo(md, i)
      n = md[:inst].name.to_s.strip
      n = (md[:inst].get_attribute(DA_DB, '_name') || '').to_s.strip if n.empty?
      n = '' if n =~ /\A(DinaBox|modulo_|torre|balcao)/i && n !~ /\s/
      tipo = { 'torre' => 'Torre', 'balcao' => 'Balcão', 'aereo' => 'Aéreo' }[md[:sm]] || md[:sm].capitalize
      n.empty? ? "#{tipo} #{i + 1}" : n
    end

    # ---- cenas (dentro da operação do gerar): módulo sozinho, de frente sem portas + 3D com portas ----
    def self.cenas_modulos(m)
      m.pages.to_a.select { |p| p.name =~ /\APCF M\d+ / }.each { |p| m.pages.erase(p) }
      res = []
      modulos(m).each_with_index do |md, i|
        pecas, portas = pecas_modulo(md)
        next if pecas.size < 3
        fr = frente(md, portas); b = base_vista(fr)
        # esconde tudo que não é o caminho até o módulo
        escondidos = []
        nivel = m.entities
        md[:cam].each do |anc|
          nivel.each { |e| next if e == anc || !(e.is_a?(Sketchup::Drawingelement)) || e.hidden?; e.hidden = true; escondidos << e }
          nivel = anc.definition.entities
        end
        ce = md[:bb].center; dg = md[:bb].diagonal
        n2 = format('%02d', i + 1)
        c3d = Sketchup::Camera.new(ce.offset((fr + b[0] * 0.6 + Geom::Vector3d.new(0, 0, 0.5)).normalize, dg * 2.2), ce, Z_AXIS, true, 35.0)
        nome3 = "PCF M#{n2} 3D"; cena(m, nome3, c3d)
        portas.each { |p, _| next if p.hidden?; p.hidden = true; escondidos << p }
        cf = Sketchup::Camera.new(ce.offset(fr, dg * 3), ce, Z_AXIS, false)
        (cf.height = [md[:bb].depth, dg].max * 1.2) rescue nil
        nomef = "PCF M#{n2} FRENTE"; cena(m, nomef, cf)
        escondidos.each { |e| e.hidden = false rescue nil }
        alturas, larguras, cx = vaos(pecas, b)
        u0 = cx.map { |p| p[:u0] }.min; u1 = cx.map { |p| p[:u1] }.max
        v0 = md[:bb].min.z; v1 = md[:bb].max.z
        w1 = faixa(md[:bb], fr)[1]
        prof = (faixa(md[:bb], fr)[1] - faixa(md[:bb], fr)[0]).to_mm.round
        res << { nome: nome_modulo(md, i), frente: nomef, d3: nome3, b: b, w: w1, u0: u0, u1: u1, v0: v0, v1: v1,
                 alturas: alturas, larguras: larguras, prof: prof, portas: portas.size }
      end
      res
    end


    # ---- liga as folhas de módulo no gerar do detalhamento.rb (ajusta o código dele na memória, sem mexer no arquivo) ----
    # também dá para testar sem mexer no projeto: gerar('C:/.../copia.skp') cria as cenas, salva uma CÓPIA, desfaz tudo e monta o LayOut da cópia
    def self.ligar_modulos
      f = File.join(__dir__, 'detalhamento.rb')
      return unless File.exist?(f)
      s = File.read(f, encoding: 'UTF-8')
      return if s.include?('cenas_modulos(m)')   # versão que já vem com isso
      trocas = [
        [/def self\.gerar\r?\n/, "def self.gerar(teste = nil)\n      @teste = teste; @resultado = nil\n"],
        [/(m\.entities\.active_section_plane = nil rescue nil\r?\n)/, "\\1      mods = (cenas_modulos(m) rescue (@erros << \"módulos: \#{$!.message}\"; []))\n"],
        [/m\.commit_operation\r?\n(\s*)m\.save\r?\n/, "@nomes_cenas = m.pages.map(&:name)\n\\1m.commit_operation\n\\1if @teste then m.save_copy(@teste); Sketchup.undo else m.save end\n"],
        [/idx = ->\(nome\) \{ m\.pages\.to_a\.index \{ \|p\| p\.name == nome \} \}/, "idx = ->(nome) { @nomes_cenas.index(nome) }"],
        [/Layout::SketchUpModel\.new\(m\.path,/, "Layout::SketchUpModel.new(@teste || m.path,"],
        [/saida = pasta_saida\(m, info\)/, "saida = @teste ? @teste.sub(/\\.skp\\z/i, '.layout') : pasta_saida(m, info)"],
        [/(\s*)@doc\.save\(saida\)/, "\\1(folhas_modulos(m, mods, info, idx) rescue @erros << \"folhas dos módulos: \#{$!.message}\")\\1@doc.save(saida)"],
        [/UI\.messagebox\(msg\)/, "@resultado = msg; UI.messagebox(msg) unless @teste"],
        [/if File\.exist\?\(pdf\)\r?\n(\s*)rescue => e\r?\n/, "if File.exist?(pdf) && !@teste\n\\1rescue => e\n\\1  (@resultado = \"ERRO \#{e.message} \#{e.backtrace.first(3).join(' ')}\"; return) if @teste\n"]
      ]
      trocas.each do |re, novo|
        n = s.scan(re).size
        raise "detalhamento.rb mudou (não achei: #{re.source[0, 40]})" unless n >= 1
        s = s.gsub(re, novo)
      end
      eval(s, TOPLEVEL_BINDING, f)
      true
    end

    # ---- folhas no LayOut ----
    def self.folhas_modulos(m, mods, info, idx)
      mods.each_with_index do |fm, i|
        pg = @doc.pages.add("MÓDULO #{i + 1}")
        ax, ay, aw, ah = 14.0, 22.0, 168.0, 160.0
        vp = Layout::SketchUpModel.new(@teste || Sketchup.active_model.path, b2(ax, ay, aw, ah)); add(vp, pg)
        prep(vp, idx.(fm[:frente]))
        escala_modulo(vp, fm, aw, ah)
        cotar_modulo(pg, vp, fm)
        v3 = Layout::SketchUpModel.new(@teste || Sketchup.active_model.path, b2(190.0, 22.0, 98.0, 98.0)); add(v3, pg)
        prep(v3, idx.(fm[:d3]))
        larg = (fm[:u1] - fm[:u0]).to_mm.round; alt = (fm[:v1] - fm[:v0]).to_mm.round
        txt(pg, "#{fm[:nome]}\nLargura #{larg} · Altura #{alt} · Profundidade #{fm[:prof]} mm\n" \
                "Vista de frente sem portas#{fm[:portas] > 0 ? " (#{fm[:portas]} porta(s) / frente(s) escondidas)" : ''}",
            190.0, 124.0, 98.0, 30.0, tam: 9)
        txt_c(pg, "MÓDULO #{i + 1} — #{fm[:nome].upcase}", 148.5, 15.2, tam: 10, fundo: c(255, 255, 255), sem_traco: true)
        moldura(pg, info)
      end
    end

    def self.escala_modulo(vp, fm, aw, ah)
      ew = (fm[:u1] - fm[:u0]).to_mm; eh = (fm[:v1] - fm[:v0]).to_mm
      fit = [(aw - 30) / [ew, 1].max, (ah - 30) / [eh, 1].max].min
      esc = [5, 10, 15, 20, 25, 30, 40, 50, 75, 100].find { |k| 1.0 / k <= fit } || 100
      vp.scale = 1.0 / esc
      a = vp.model_to_paper_point(pt3(fm[:u0], fm[:v0], fm[:w], fm[:b])); bq = vp.model_to_paper_point(pt3(fm[:u0] + 1000.mm, fm[:v0], fm[:w], fm[:b]))
      vp.scale = esc.to_f if ((a.distance(bq) * IN) - 1000.0 / esc).abs > 1000.0 / esc * 0.2
      fm[:esc] = esc
    rescue => e
      @erros << "escala módulo: #{e.message}"
    end

    def self.cotar_modulo(pg, vp, fm)
      b = fm[:b]; w = fm[:w]
      pp = ->(u, v) { proj(vp, pt3(u, v, w, b)) }
      xl, yb = pp.(fm[:u0], fm[:v0]); xr, yt = pp.(fm[:u1], fm[:v1])
      # largura total em cima e altura total à direita
      cota_h(pg, xl, xr, yt - 7.0, (fm[:u1] - fm[:u0]).to_mm.round, yt, yt)
      cota_v(pg, xr + 7.0, yt, yb, (fm[:v1] - fm[:v0]).to_mm.round, xr + 3.0)
      # altura de cada vão, por coluna (por dentro)
      fm[:alturas].each do |uc, va, vb|
        x, ya = pp.(uc, va); _, yb2 = pp.(uc, vb)
        next if (ya - yb2).abs < 6
        cota_v(pg, x, yb2, ya, (vb - va).to_mm.round)
      end
      # largura de cada vão, por faixa
      fm[:larguras].each do |vc, ch|
        ch.each do |ua, ub|
          xa, y = pp.(ua, vc); xb, _ = pp.(ub, vc)
          next if (xb - xa).abs < 8
          cota_h(pg, xa, xb, y - 4.0, (ub - ua).to_mm.round)
        end
      end
      txt(pg, "ESC. 1:#{fm[:esc]}", 150.0, 176.0, 30.0, 5.0, tam: 8) if fm[:esc]
    end
  end
end

(PCFLabel::Detalhar.ligar_modulos rescue (puts "PCF Detalhamento módulos: #{$!.message}"))
