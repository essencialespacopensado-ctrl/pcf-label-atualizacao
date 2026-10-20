module PCFLabel
  def self.coletar_teste(ents, tr, cam, pecas, pai_bb = nil, pids = [], herd = nil, origem = nil, gira = false)
    ents.each do |e|
      next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
      next if e.hidden? || !camada_visivel?(e.layer)
      next if e.get_attribute('pcf', 'nome') || e.name == 'PCF Nome'    # texto 3D do nome não é peça
      next if usinagem?(e)                                             # linha de fresa / linha de conferência não é peça
      # portas/trilhos do botão Correr, projeto da porta de alumínio e frentes guardadas da peça mãe: não são corte (só compras)
      next if e.get_attribute('pcf', 'nao_cortar') || e.get_attribute('pcf', 'correr_modulo') || e.get_attribute('pcf', 'projeto_alu') || e.get_attribute('pcf', 'cofre_mae')
      # modelagem que o PCF Ferramentas já transformou em tamponamento/chapa aberta: corta só o tamponamento
      vid = e.get_attribute('pcf', 'virou')
      next if vid && (Sketchup.active_model.find_entity_by_persistent_id(vid.to_i) rescue nil)
      d = e.definition
      orig = origem || origem_de(e, d)
      t = tr * e.transformation
      gira_e = gira || !!e.get_attribute('pcf', 'veio_girado')   # botão "Inverter veio" do PCF Ferramentas (na peça ou no móvel)
      filhos = d.entities.select { |x| (x.is_a?(Sketchup::Group) || x.is_a?(Sketchup::ComponentInstance)) && !x.get_attribute('pcf', 'nome') && x.name != 'PCF Nome' && !usinagem?(x) }
      faces = d.entities.grep(Sketchup::Face)
      nome = e.name.to_s.empty? ? d.name.to_s : e.name.to_s
      if faces.size >= 4 && filhos.empty?
        # objeto muito detalhado (sofá, ferragem, puxador) não é chapa: descarta antes da conta pesada
        next if faces.size > 1500
        # ferragem pelo nome (dobradiça, puxador, corrediça…) não é chapa
        # (também pelo nome do grupo de fora: a corrediça do Dinabox é "dinabox_corredica" > "Painel 63")
        txt_f = "#{e.name} #{d.name} #{e.get_attribute('dynamic_attributes', 'descricao')} #{d.get_attribute('dynamic_attributes', 'descricao')} #{cam.last(2).join(' ')}"
        next if txt_f =~ /dobradi|puxador|corredi|ferrage|parafus|cavilha|minifix|rodizi|p[eé] regul|trilho|fita led/i
        if orig
          # medida de verdade pelos pontos (a caixa do componente × escala errava em peça girada do Dinabox e jogava fora
          # sarrafos e avulsas de 18,3 como se fossem "grossos")
          vw0 = d.entities.grep(Sketchup::Edge).flat_map(&:vertices).uniq.map { |vv| vv.position.transform(t) }
          dd0 = [t.xaxis, t.yaxis, t.zaxis].map { |a| a = a.normalize; ds = vw0.map { |q| q.x * a.x + q.y * a.y + q.z * a.z }; ds.empty? ? 0 : (ds.max - ds.min).to_mm }.sort
          next if dd0[0] > 65   # mais grosso que chapa
        end
        # tudo no espaço do modelo (já com escala/rotação do grupo)
        vs = d.entities.grep(Sketchup::Edge).flat_map(&:vertices).uniq.map { |vv| vv.position.transform(t) }
        info = faces.map do |fc|
          pp = fc.outer_loop.vertices.map { |vv| vv.position.transform(t) }
          nx = ny = nz = 0.0
          pp.each_with_index { |p, i| q = pp[(i + 1) % pp.size]; nx += (p.y - q.y) * (p.z + q.z); ny += (p.z - q.z) * (p.x + q.x); nz += (p.x - q.x) * (p.y + q.y) }
          ar = Math.sqrt(nx * nx + ny * ny + nz * nz)
          next nil if ar < 1e-9
          { f: fc, pts: pp, n: Geom::Vector3d.new(nx / ar, ny / ar, nz / ar), area: ar / 2 }
        end.compact
        next if info.empty?
        ext = ->(n) { ds = vs.map { |p| p.x * n.x + p.y * n.y + p.z * n.z }; ds.max - ds.min }
        grandes = info.select { |x| x[:area] > info.map { |y| y[:area] }.max * 0.05 }
        # espessura = menor medida entre as faces (não depende de qual face é maior)
        nesp = grandes.min_by { |x| ext.(x[:n]) }[:n]
        esp = ext.(nesp).to_mm.round(1)
        if orig
          dims = [ext.(Geom::Vector3d.new(1, 0, 0)), ext.(Geom::Vector3d.new(0, 1, 0)), ext.(Geom::Vector3d.new(0, 0, 1))].map(&:to_mm).sort
          next if esp < 2.5 || esp > 60
        end
        # chapa é plana: as faces ficam paralelas ou em esquadro com a face grande; peça curva/torneada (dobradiça, puxador) não
        a_tot = info.sum { |x| x[:area] }
        a_torta = info.select { |x| c = (x[:n] % nesp).abs; c > 0.02 && c < 0.98 }.sum { |x| x[:area] }
        next if a_tot > 0 && a_torta / a_tot > 0.03
        fi = info.select { |x| (x[:n] % nesp).abs > 0.999 }.max_by { |x| x[:area] }
        n = fi[:n]; pts3 = fi[:pts]; f = fi[:f]
        # orientação como no projeto: vertical = altura do projeto; deitada = eixo X do modelo
        z = Geom::Vector3d.new(0, 0, 1)
        if (n % z).abs > 0.99
          xx = Geom::Vector3d.new(1, 0, 0); u = (xx - Geom::Vector3d.new(n.x * (xx % n), n.y * (xx % n), n.z * (xx % n))).normalize
          v = n * u
        else
          v = (z - Geom::Vector3d.new(n.x * (z % n), n.y * (z % n), n.z * (z % n))).normalize
          u = v * n
        end
        # veio como está NA TELA: se a cor tem veio (riscas numa direção na imagem), o "vertical" da peça no plano
        # passa a ser a direção do veio da textura nesta face (rodapé/travessa em pé com veio deitado sai certo)
        mobj = f.material || e.material || (herd && Sketchup.active_model.materials.find { |mm| mm.display_name == herd || mm.name == herd })
        if (vt = dir_veio_textura(f, t, mobj, n))
          v = vt
          u = v * n
        end
        u, v = v, u.reverse if gira_e   # veio invertido: a peça entra no plano girada 90° (sem redesenhar)
        o = pts3[0]
        # lê a peça como ela é: furos que atravessam e rebaixos (fundo em profundidade intermediária)
        dep = ->(p) { (p - o) % n }                       # 0 na face de cima, -esp na de baixo
        paral = info.select { |x| (x[:n] % n).abs > 0.999 }
        esp_mm = esp
        fundos = paral.select { |x| dd = dep.(x[:pts][0]).to_mm; dd < -0.3 && dd > -(esp_mm - 0.3) }
        rebs = fundos.map do |x|
          dd = -dep.(x[:pts][0]).to_mm                    # distância da face de cima
          de_cima = (x[:n] % n) > 0                        # fundo olhando para cima = rebaixo aberto em cima
          { pts3: x[:pts], prof: (de_cima ? dd : esp_mm - dd).round(2), lado: de_cima ? 1 : -1 }
        end
        # usinagens da fresa do Dinabox (orgânico, ranhuras): contorno por fora, furos e rebaixos por dentro
        pl_cont = nil; pl_furos = []; pl_rebs = []
        d.entities.each do |pl|
          next unless pl.respond_to?(:definition) && pl.get_attribute('dinabox', 'polyline').is_a?(String)
          dados = (JSON.parse(pl.get_attribute('dinabox', 'polyline')) rescue nil)
          next unless dados
          raio = dados['di'].to_f.mm / 2.0
          pz = dados['pz'].to_f
          tp = t * pl.transformation
          cadeias(pl.definition).each do |lp, fechado|
            w = lp.map { |p| p.transform(tp) }
            prof_plano = dep.(w[0])                       # em que face está desenhada
            uv2 = w.map { |p| q = p - o; [q % u, q % v] }
            if fechado && uv2.size >= 3
              final = afastar2(uv2, dados['align'].to_s == '1' ? -raio : raio)
            elsif uv2.size == 2                           # linha reta aberta: ranhura da largura da fresa
              a, b = uv2; dx = b[0] - a[0]; dy = b[1] - a[1]; l = Math.hypot(dx, dy)
              next if l < 1e-6
              nx = -dy / l * raio; ny = dx / l * raio
              final = [[a[0] + nx, a[1] + ny], [b[0] + nx, b[1] + ny], [b[0] - nx, b[1] - ny], [a[0] - nx, a[1] - ny]]
            else
              next
            end
            p3 = final.map { |x, y| o.offset(u, x).offset(v, y).offset(n, prof_plano) }
            atravessa = pz >= esp_mm - 0.3
            if dados['align'].to_s == '1'
              if atravessa
                arf = ->(pp) { s2 = 0.0; pp.each_with_index { |q1, k| q2 = pp[(k + 1) % pp.size]; s2 += q1[0] * q2[1] - q2[0] * q1[1] }; s2.abs / 2 }
                pl_cont = [p3, arf.(final)] if pl_cont.nil? || arf.(final) > pl_cont[1]
              end
            elsif atravessa
              pl_furos << p3
            else
              lado = -prof_plano.to_mm < esp_mm / 2.0 ? 1 : -1
              pl_rebs << { pts3: p3, prof: pz.round(2), lado: lado, pl: true }
            end
          end
        end
        rebs.concat(pl_rebs)
        # se a maioria dos rebaixos é do outro lado, vira a peça (a máquina só usina por cima)
        virar = rebs.count { |r| r[:lado] < 0 } > rebs.count { |r| r[:lado] > 0 }
        p2 = ->(p) { w = p - o; [((virar ? -1 : 1) * (w % u)).to_mm.round(2), (w % v).to_mm.round(2)] }
        # contorno de corte: a maior face (frente ou verso) — rebaixo na borda não diminui a peça
        f_baixo = paral.select { |x| dep.(x[:pts][0]).to_mm <= -(esp_mm - 0.3) }.max_by { |x| x[:area] }
        a_cima = fi[:area]; a_baixo = f_baixo ? f_baixo[:area] : 0
        ext_loop = ->(fc) { fc.outer_loop.vertices.map { |vv| vv.position.transform(t) } }
        ar2 = ->(pp) { s2 = 0.0; pp.each_with_index { |q1, k| q2 = pp[(k + 1) % pp.size]; s2 += q1[0] * q2[1] - q2[0] * q1[1] }; (s2 / 2).abs }
        cand = [ext_loop.(f)]; cand << ext_loop.(f_baixo[:f]) if f_baixo
        contorno = cand.map { |pp| pp.map { |p| p2.(p) } }.max_by { |pp| ar2.(pp) }
        contorno = pl_cont[0].map { |p| p2.(p) } if pl_cont   # recorte feito com a fresa do Dinabox: a peça é o contorno da fresa
        # furos: buracos que aparecem nas duas faces (atravessam)
        buracos = ->(fc) { fc ? fc.loops.reject(&:outer?).map { |lp| lp.vertices.map { |vv| p2.(vv.position.transform(t)) } } : [] }
        cen = ->(pp) { [pp.sum { |q| q[0] } / pp.size, pp.sum { |q| q[1] } / pp.size] }
        dentro2 = ->(pt, pp) { c = false; j = pp.size - 1; pp.each_with_index { |q, i2| r = pp[j]; c = !c if ((q[1] > pt[1]) != (r[1] > pt[1])) && (pt[0] < (r[0] - q[0]) * (pt[1] - q[1]) / (r[1] - q[1]) + q[0]); j = i2 }; c }
        rebs2 = rebs.map { |r| { pts: r[:pts3].map { |p| p2.(p) }, prof: r[:prof], lado: (virar ? -r[:lado] : r[:lado]), pl: r[:pl], p3: r[:pts3] } }
        # ranhura que passa da borda: só até a borda da peça (o contorno corta o resto)
        unless pl_rebs.empty?
          xs = contorno.map(&:first); ys = contorno.map(&:last)
          caixa = [xs.min, ys.min, xs.max, ys.max]
          rebs2 = rebs2.map { |r| r[:pl] ? r.merge(pts: recortar2(r[:pts], caixa).map { |x, y| [x.round(2), y.round(2)] }) : r }.reject { |r| r[:pts].size < 3 }
        end
        rebs2.each { |r| r.delete(:pl) }
        rebs3 = rebs2.map { |r| r.delete(:p3) }
        # furos com o contorno 3D junto (para mostrar no SketchUp qual recorte é qual)
        buracos3 = ->(fc) { fc ? fc.loops.reject(&:outer?).map { |lp| lp.vertices.map { |vv| vv.position.transform(t) } } : [] }
        pares = (buracos3.(f) + buracos3.(f_baixo && f_baixo[:f])).map { |h3| [h3.map { |p| p2.(p) }, h3] }
        pares = pares.reject { |h, _| c = cen.(h); rebs2.any? { |r| dentro2.(c, r[:pts]) } }
        pares += pl_furos.map { |pp| [pp.map { |p| p2.(p) }, pp] }
        # o mesmo furo visto nas duas faces conta uma vez
        pares = pares.each_with_object([]) { |(h, h3), acc| c = cen.(h); acc << [h, h3] unless acc.any? { |g, _| g2 = cen.(g); (g2[0] - c[0]).abs < 1 && (g2[1] - c[1]).abs < 1 } }
        furos = pares.map(&:first)
        (@rec3 ||= {})[e.persistent_id.to_s] = { 'f' => pares.map(&:last), 'r' => rebs3 }
        mat = e.material ? e.material.display_name : (faces.map { |x| x.material && x.material.display_name }.compact.group_by(&:itself).max_by { |_, vv| vv.size }&.first)
        mat ||= herd
        auto = (orig == 'Dinabox' && papel_dinabox(d)) || papel(n, vs, pai_bb || Sketchup.active_model.bounds, esp)
        # móvel: no Dinabox é o módulo (moduloid); nos outros, o grupo de fora
        mod = orig == 'Dinabox' ? [e, d].map { |x| (x.get_attribute('dinabox', 'construtivo') || x.get_attribute('dinabox', 'component_id')).to_s[/moduloid,(\d+)/, 1] || x.get_attribute('dinabox', 'component_id') }.compact.first : nil
        topo_id = mod ? "dinabox-#{mod}" : (pids.first || e.persistent_id).to_s
        topo_nm = mod ? "Módulo Dinabox #{mod}" : (cam.first || nome).to_s
        pai_nome = cam.reverse.find { |c| !nome_limpo(c).empty? }
        auto = "#{auto} - #{nome_limpo(pai_nome)}" if pai_nome
        pecas << { sk: e.persistent_id.to_s, skpath: (pids + [e.persistent_id]).join('.'), cam: (cam + [nome]).join(' > '), nome: nome, auto: auto, mat: (mat || 'sem material').to_s, esp: esp_padrao(esp), contorno: contorno, furos: furos, rebaixos: rebs2, virada: virar, origem: orig || 'SketchUp', topo: topo_id, topo_nome: topo_nm }
      elsif !filhos.empty?
        bb = Geom::BoundingBox.new; d.bounds.then { |b| 8.times { |k| bb.add(b.corner(k).transform(t)) } }
        coletar_teste(d.entities, t, cam + [nome], pecas, bb, pids + [e.persistent_id], (e.material && e.material.display_name) || herd, orig, gira_e)
      end
    end
  end

end
