# PCF Label - SketchUp -> otimizador -> Aspire
# Lê só as peças modeladas (grupos/componentes sólidos), ignorando tudo que é do Dinabox.
require 'json'
module PCFLabel
  MODELO_TELA = 'C:/Users/Public/Documents/Vectric Files/Gadgets/Aspire V12.0/PCF Label/etiquetas.html'

  # a tela vem junto com o plugin: se a da pasta do Aspire for mais velha (ou não existir), instala a nova
  def self.instalar_tela
    nova = File.join(__dir__, 'etiquetas.html')
    return unless File.exist?(nova)
    ver = ->(f) { (File.read(f, encoding: 'UTF-8')[/VERSAO = '([^']+)'/, 1] rescue nil).to_s }
    return if File.exist?(MODELO_TELA) && ver.(MODELO_TELA) >= ver.(nova)
    require 'fileutils'
    FileUtils.mkdir_p(File.dirname(MODELO_TELA))
    FileUtils.cp(nova, MODELO_TELA)
  rescue
    nil
  end

  def self.dinabox?(e, d)
    t = "#{e.name} #{d.name}"
    return true if t =~ /dinabox|\bdb_/i
    return true if d.attribute_dictionaries && d.attribute_dictionaries.any? { |ad| ad.name =~ /dinabox/i }
    return true if e.attribute_dictionaries && e.attribute_dictionaries.any? { |ad| ad.name =~ /dinabox/i }
    false
  end

  # tag visível de verdade (a tag e as pastas de tags acima dela)
  def self.camada_visivel?(l)
    return true unless l
    return false unless l.visible?
    f = (l.folder rescue nil)
    while f
      return false unless f.visible?
      f = (f.folder rescue nil)
    end
    true
  end

  # de que programa a peça veio (nil = desenhada no SketchUp)
  def self.origem_de(e, d)
    return 'Dinabox' if dinabox?(e, d)
    ds = [e, d].flat_map { |x| (x.attribute_dictionaries || []).map(&:name) }.join(' ')
    return 'Promob' if ds =~ /promob/i
    return 'Gabster' if ds =~ /gabster/i
    return 'Moduloft' if ds =~ /moduloft/i
    nil
  end

  # nome da peça que o Dinabox já dá (dinabox_peca_tamponamento_interno_#12 -> Tamponamento interno)
  def self.papel_dinabox(d)
    t = d.name.to_s[/dinabox_peca_([a-z_]+)/i, 1].to_s.sub(/_+\d*$/, '').tr('_', ' ').strip
    t.empty? ? nil : t.capitalize
  end

  # ---- usinagens desenhadas com a fresa do Dinabox (PCF Ferramentas: orgânico, ranhuras, rebaixo de moldura) ----
  # dinabox_polyline = caminho do CENTRO da fresa; align 1 = por fora, 2 = por dentro; pz = profundidade (mm)
  def self.usinagem?(x)
    x.get_attribute('dinabox', 'polyline').is_a?(String) ||
      (x.respond_to?(:definition) && x.definition.name =~ /dinabox_polyline/i) ||
      x.get_attribute('pcf', 'tipo') == 'linha_corte'
  end

  # laços (fechados ou abertos) das arestas de uma polyline, em ordem
  def self.cadeias(defn)
    eds = defn.entities.grep(Sketchup::Edge)
    viz = Hash.new { |hh, k| hh[k] = [] }
    eds.each { |ed| viz[ed.start] << ed; viz[ed.end] << ed }
    usadas = {}
    res = []
    inicio = viz.keys.sort_by { |vx| viz[vx].size == 1 ? 0 : 1 }
    inicio.each do |v0|
      next if viz[v0].all? { |ed| usadas[ed] }
      pts = [v0.position]; v = v0; fechado = false
      loop do
        ed = viz[v].find { |x| !usadas[x] }
        break unless ed
        usadas[ed] = true
        v = ed.other_vertex(v)
        if v == v0 then fechado = true; break end
        pts << v.position
      end
      if !fechado && pts.size > 3 && pts.first == pts.last # fechou num vértice repetido (== já usa a tolerância do SketchUp)
        pts.pop; fechado = true
      end
      res << [pts, fechado] if pts.size >= 2
    end
    res
  end

  # afasta um contorno 2D (d > 0 para fora, d < 0 para dentro)
  def self.afastar2(pts, d)
    n = pts.size
    return pts if n < 3 || d.abs < 1e-9
    ar = 0.0
    pts.each_with_index { |p, i| q = pts[(i + 1) % n]; ar += p[0] * q[1] - q[0] * p[1] }
    sg = ar > 0 ? 1.0 : -1.0 # anti-horário: normal para fora = (dy, -dx)
    pts.each_with_index.map do |p, i|
      a = pts[i - 1]; b = pts[(i + 1) % n]
      e1 = [p[0] - a[0], p[1] - a[1]]; e2 = [b[0] - p[0], b[1] - p[1]]
      l1 = Math.hypot(*e1); l2 = Math.hypot(*e2)
      next p if l1 < 1e-9 || l2 < 1e-9
      n1 = [sg * e1[1] / l1, -sg * e1[0] / l1]; n2 = [sg * e2[1] / l2, -sg * e2[0] / l2]
      m = [n1[0] + n2[0], n1[1] + n2[1]]; ml = Math.hypot(*m)
      next [p[0] + n1[0] * d, p[1] + n1[1] * d] if ml < 1e-9
      cs = (m[0] * n1[0] + m[1] * n1[1]) / ml
      k = d / [cs, 0.2].max
      [p[0] + m[0] / ml * k, p[1] + m[1] / ml * k]
    end
  end

  # recorta um polígono 2D na caixa [x0,y0,x1,y1] (Sutherland-Hodgman)
  def self.recortar2(pts, cx)
    x0, y0, x1, y1 = cx
    lados = [[->(p) { p[0] >= x0 }, ->(a, b) { t = (x0 - a[0]) / (b[0] - a[0]); [x0, a[1] + t * (b[1] - a[1])] }],
             [->(p) { p[0] <= x1 }, ->(a, b) { t = (x1 - a[0]) / (b[0] - a[0]); [x1, a[1] + t * (b[1] - a[1])] }],
             [->(p) { p[1] >= y0 }, ->(a, b) { t = (y0 - a[1]) / (b[1] - a[1]); [a[0] + t * (b[0] - a[0]), y0] }],
             [->(p) { p[1] <= y1 }, ->(a, b) { t = (y1 - a[1]) / (b[1] - a[1]); [a[0] + t * (b[0] - a[0]), y1] }]]
    lados.each do |dentro, corta|
      ent = pts; pts = []
      next if ent.empty?
      ent.each_with_index do |p, i|
        a = ent[i - 1]
        if dentro.(p)
          pts << corta.(a, p) unless dentro.(a)
          pts << p
        elsif dentro.(a)
          pts << corta.(a, p)
        end
      end
    end
    pts
  end

  # espessura de chapa no padrão da empresa: 18 -> 18,3 (6,3 / 15,3 / 18,3 / 25,3) e chapas coladas (21,6 = 15,3 + 6,3 …).
  # Peça desenhada com 18 ou 18,3 vira o mesmo material na lista (não sai "Freijó 18" e "Freijó 18,3" separados)
  ESP_PADRAO = { 6 => 6.3, 15 => 15.3, 18 => 18.3, 25 => 25.3, 21 => 21.6, 24 => 24.6, 30 => 30.6, 31 => 31.6, 33 => 33.6, 36 => 36.6 }.freeze
  def self.esp_padrao(e)
    n = e.to_f.round
    (e.to_f - n).abs < 0.15 && ESP_PADRAO[n] ? ESP_PADRAO[n] : e
  end

  # direção do veio da imagem da cor: :v (riscas na vertical da imagem), :u (na horizontal) ou nil (sem veio claro)
  def self.veio_imagem(mt)
    return nil unless mt && mt.texture
    @veio_img ||= {}
    return @veio_img[mt.name] if @veio_img.key?(mt.name)
    r = nil
    begin
      ir = mt.texture.image_rep
      w = ir.width; h = ir.height
      st = [[w, h].min / 100, 1].max
      lum = ->(c) { c.red * 0.3 + c.green * 0.59 + c.blue * 0.11 }
      dx = 0.0; dy = 0.0
      (st...h - st).step(st) do |y|
        (st...w - st).step(st) do |x|
          c0 = lum.(ir.color_at_uv(x.to_f / w, y.to_f / h))
          dx += (c0 - lum.(ir.color_at_uv((x + 1).to_f / w, y.to_f / h))).abs
          dy += (c0 - lum.(ir.color_at_uv(x.to_f / w, (y + 1).to_f / h))).abs
        end
      end
      r = dx > dy * 2 ? :v : (dy > dx * 2 ? :u : nil)   # muda pouco na vertical = riscas verticais = veio em V
    rescue StandardError
      r = nil
    end
    @veio_img[mt.name] = r
  end

  # direção (no mundo, no plano da face) do veio da textura nesta face; nil se a cor não tem veio claro
  def self.dir_veio_textura(f, t, mt, n)
    eixo = veio_imagem(mt)
    return nil unless eixo
    ps = f.outer_loop.vertices.map(&:position)
    p0, p1 = ps[0], ps[1]
    p2 = ps.find { |q| ((p1 - p0) * (q - p0)).length > 1e-6 }
    return nil unless p2
    uvh = f.get_UVHelper(true, false)
    uv = [p0, p1, p2].map { |q| r = uvh.get_front_UVQ(q); [r.x / r.z, r.y / r.z] }
    du1 = uv[1][0] - uv[0][0]; dv1 = uv[1][1] - uv[0][1]; du2 = uv[2][0] - uv[0][0]; dv2 = uv[2][1] - uv[0][1]
    det = du1 * dv2 - du2 * dv1
    return nil if det.abs < 1e-12
    e1 = p1 - p0; e2 = p2 - p0
    # derivada da posição: em U = (e1*dv2 - e2*dv1)/det ; em V = (e2*du1 - e1*du2)/det
    a = eixo == :v ? [e2, du1, e1, du2] : [e1, dv2, e2, dv1]
    vv = Geom::Vector3d.new((a[0].x * a[1] - a[2].x * a[3]) / det, (a[0].y * a[1] - a[2].y * a[3]) / det, (a[0].z * a[1] - a[2].z * a[3]) / det).transform(t)
    vv = vv - Geom::Vector3d.new(n.x * (vv % n), n.y * (vv % n), n.z * (vv % n))
    return nil if vv.length < 1e-9
    vv.normalize!
    # mantém o sentido "para cima / para +X" (não espelha a peça à toa)
    vv.reverse! if vv.z < -1e-6 || (vv.z.abs <= 1e-6 && (vv.x < -1e-6 || (vv.x.abs <= 1e-6 && vv.y < 0)))
    vv
  rescue StandardError
    nil
  end

  def self.coletar(ents, tr, cam, pecas, pai_bb = nil, pids = [], herd = nil, origem = nil, gira = false)
    @virou_cache = nil if cam.empty? && ents.is_a?(Sketchup::Entities) && (ents.parent.is_a?(Sketchup::Model) rescue false)   # coleta nova do projeto: procura de novo
    ents.each do |e|
      next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
      next if e.hidden? || !camada_visivel?(e.layer)
      next if e.get_attribute('pcf', 'nome') || e.name == 'PCF Nome'    # texto 3D do nome não é peça
      next if usinagem?(e)                                             # linha de fresa / linha de conferência não é peça
      # portas/trilhos do botão Correr, projeto da porta de alumínio e frentes guardadas da peça mãe: não são corte (só compras)
      next if e.get_attribute('pcf', 'nao_cortar') || e.get_attribute('pcf', 'correr_modulo') || e.get_attribute('pcf', 'projeto_alu') || e.get_attribute('pcf', 'cofre_mae')
      # modelagem que o PCF Ferramentas já transformou em tamponamento/chapa aberta: corta só o tamponamento
      vid = e.get_attribute('pcf', 'virou')
      next if vid && virou_existe?(vid)
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
        txt_f = "#{e.name} #{d.name} #{e.get_attribute('dynamic_attributes', 'descricao')} #{d.get_attribute('dynamic_attributes', 'descricao')}"
        next if txt_f =~ /dobradi|puxador|corredi|ferrage|parafus|cavilha|minifix|rodizi|p[eé] regul|trilho|fita led/i
        if orig
          db0 = d.bounds; sc = [t.xaxis.length, t.yaxis.length, t.zaxis.length]
          dd0 = [db0.width * sc[0], db0.height * sc[1], db0.depth * sc[2]].map(&:to_mm).sort
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
        pl_cont = nil; pl_furos = []; pl_rebs = []; pl_linhas = []
        pl_pontes = {} # trechos do corte de dentro com pontes (PCF Ferramentas): juntam de volta num furo só
        d.entities.each do |pl|
          next unless pl.respond_to?(:definition) && pl.get_attribute('dinabox', 'polyline').is_a?(String)
          dados = (JSON.parse(pl.get_attribute('dinabox', 'polyline')) rescue nil)
          next unless dados
          raio = dados['di'].to_f.mm / 2.0
          pz = dados['pz'].to_f
          tp = t * pl.transformation
          cadeias(pl.definition).each do |lp, fechado|
            linha_uv = nil
            w = lp.map { |p| p.transform(tp) }
            prof_plano = dep.(w[0])                       # em que face está desenhada
            uv2 = w.map { |p| q = p - o; [q % u, q % v] }
            if dados['pcf'].to_s == 'ponte' && !fechado
              (pl_pontes[dados['grp'].to_s] ||= []) << { ord: dados['ord'].to_i, uv: uv2, pp: prof_plano, raio: raio, pz: pz }
              next
            end
            if fechado && uv2.size >= 3
              final = afastar2(uv2, dados['align'].to_s == '1' ? -raio : raio)
            elsif uv2.size == 2                           # linha reta aberta: ranhura da largura da fresa
              a, b = uv2; dx = b[0] - a[0]; dy = b[1] - a[1]; l = Math.hypot(dx, dy)
              next if l < 1e-6
              nx = -dy / l * raio; ny = dx / l * raio
              final = [[a[0] + nx, a[1] + ny], [b[0] + nx, b[1] + ny], [b[0] - nx, b[1] - ny], [a[0] - nx, a[1] - ny]]
              linha_uv = [a, b]
            else
              next
            end
            p3 = final.map { |x, y| o.offset(u, x).offset(v, y).offset(n, prof_plano) }
            atravessa = pz >= esp_mm - 0.3
            # linha aberta (ranhura da fresa, ex.: corte/marcação entre as frentes da Peça Mãe): vai com a PRÓPRIA fresa (Ø 'di'),
            # em 'pas' passadas, atravessando ou na profundidade pz
            if linha_uv
              l3 = linha_uv.map { |x, y| o.offset(u, x).offset(v, y).offset(n, prof_plano) }
              pl_linhas << { pts3: p3, l3: l3, di: dados['di'].to_f, prof: pz.round(2), passa: atravessa, pas: dados['pas'].to_i }
              next
            end
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
        pl_pontes.each_value do |tr|
          tr = tr.sort_by { |x| x[:ord] }
          uv = tr.flat_map { |x| x[:uv] }
          next if uv.size < 3
          final = afastar2(uv, tr[0][:raio])
          next unless tr[0][:pz] >= esp_mm - 0.3
          pl_furos << final.map { |x, y| o.offset(u, x).offset(v, y).offset(n, tr[0][:pp]) } # o PCF Label faz as pontes dele no G-code
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
        linhas2 = pl_linhas.map { |r| { pts: r[:pts3].map { |q| p2.(q) }, linha: r[:l3].map { |q| p2.(q) }, di: r[:di], prof: r[:prof], passa: r[:passa], pas: r[:pas] } }
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
        pecas << { sk: e.persistent_id.to_s, skpath: (pids + [e.persistent_id]).join('.'), cam: (cam + [nome]).join(' > '), nome: nome, auto: auto, mat: (mat || 'sem material').to_s, esp: esp_padrao(esp), contorno: contorno, furos: furos, rebaixos: rebs2, linhas: linhas2, virada: virar, origem: orig || 'SketchUp', topo: topo_id, topo_nome: topo_nm }
      elsif !filhos.empty?
        bb = Geom::BoundingBox.new; d.bounds.then { |b| 8.times { |k| bb.add(b.corner(k).transform(t)) } }
        coletar(d.entities, t, cam + [nome], pecas, bb, pids + [e.persistent_id], (e.material && e.material.display_name) || herd, orig, gira_e)
      end
    end
  end

  # numera as peças no modelo com o mesmo nº do plano de corte do PCF Label
  def self.numerar
    m = Sketchup.active_model
    ents = []
    pegar = lambda do |es, tr|
      es.each do |e|
        next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        next if e.hidden? || (e.layer && !e.layer.visible?)
        d = e.definition
        next if dinabox?(e, d)
        filhos = d.entities.select { |x| x.is_a?(Sketchup::Group) || x.is_a?(Sketchup::ComponentInstance) }
        faces = d.entities.grep(Sketchup::Face)
        if faces.size >= 4 && filhos.empty? then ents << e
        elsif !filhos.empty? then pegar.(d.entities, tr) end
      end
    end
    pegar.(m.entities, nil)
    pecas = []
    coletar(m.entities, Geom::Transformation.new, [], pecas)
    ids = pecas.map { |p| p[:sk] }
    m.start_operation('PCF: numerar peças', true)
    n = 0
    ents.each do |e|
      i = ids.index(e.persistent_id.to_s)
      next unless i
      atual = e.name.to_s.sub(/^\d+\s*-\s*/, '').sub(/^Pe[çc]a \d+$/, '')
      generico = atual.empty? || atual =~ /^(agrupar|grupo|group|componente|component)\s*#?\d*$/i
      e.name = generico ? "Painel #{i + 1}" : "#{i + 1} - #{atual}"
      n += 1
    end
    m.commit_operation
    "#{n} peças numeradas"
  end

  # nome que vai para a etiqueta: tira "Peça 12" / "12 - " e ignora nomes automáticos (Agrupar#5, Group#3, Componente#2)
  def self.nome_limpo(n)
    t = n.to_s.strip.sub(/^\d+\s*-\s*/, '').sub(/^(Pe[çc]a|Painel)\s*\d+$/i, '')
    return '' if t =~ /^(agrupar|grupo|group|componente|component)\s*#?\d*$/i
    # nomes automáticos antigos (Fundo 5, Lateral direita - Armário…) viram Painel N no corte
    return '' if t =~ /^(tampo|base|prateleira|lateral( esquerda| direita)?|fundo|frente|pe[çc]a inclinada|painel|pe[çc]a)(\s+\d+)?(\s+-\s+.*)?$/i
    t
  end

  # nome automático pela posição da peça dentro do móvel (Z = altura; frente do SketchUp = lado -Y)
  def self.papel(n, vs, bb, esp)
    xs = vs.map(&:x); ys = vs.map(&:y); zs = vs.map(&:z)
    cx = (xs.min + xs.max) / 2; cy = (ys.min + ys.max) / 2; cz = (zs.min + zs.max) / 2
    a = bb.min; b = bb.max
    rel = ->(v, lo, hi) { hi - lo < 1.0 ? 0.5 : (v - lo) / (hi - lo) }
    if n.z.abs > 0.9
      r = rel.(cz, a.z, b.z)
      r > 0.85 ? 'Tampo' : (r < 0.15 ? 'Base' : 'Prateleira')
    elsif n.x.abs > 0.9
      rel.(cx, a.x, b.x) < 0.5 ? 'Lateral esquerda' : 'Lateral direita'
    elsif n.y.abs > 0.9
      if esp <= 8.0 then 'Fundo'
      else rel.(cy, a.y, b.y) > 0.5 ? 'Fundo' : 'Frente'
      end
    else
      'Peça inclinada'
    end
  end

  def self.callbacks(d)
    @dlg = d
    # cada vez que o plugin é recarregado (atualização), os avisos antigos continuam ligados no SketchUp e cada clique
    # rodava 2, 3 vezes (duas abas de impressão, plano salvo 3x…). Agora só a ligação mais nova responde.
    $pcf_cb_gen = ($pcf_cb_gen || 0) + 1; g = $pcf_cb_gen
    @dlg.add_action_callback('pcf_nomes') { |_c, json| next unless g == $pcf_cb_gen; renomear(JSON.parse(json.to_s)) rescue nil }
    @dlg.add_action_callback('pcf_selecionar') { |_c, pid| next unless g == $pcf_cb_gen; selecionar(pid.to_s) rescue nil }
    @dlg.add_action_callback('pcf_diag') { |_c, txt| next unless g == $pcf_cb_gen; (File.binwrite(File.join(ENV['APPDATA'], 'PCF Label', 'diag.json'), txt.to_s.b) rescue nil) }
    @dlg.add_action_callback('pcf_salvar_plano') { |_c, txt| next unless g == $pcf_cb_gen; begin; salvar_plano(txt.to_s); rescue => e; (File.binwrite(File.join(ENV['APPDATA'], 'PCF Label', 'erro_plano.txt'), (e.message + "\n" + e.backtrace.first(3).join("\n")).b) rescue nil); end }
    @dlg.add_action_callback('pcf_abrir_aspire') { |_c, _x| next unless g == $pcf_cb_gen; st = (abrir_aspire rescue { erro: $!.message }); @dlg.execute_script("ASPIRE_STATUS(#{JSON.generate(st)})") rescue nil }
  end

  # ---- tela do PCF dentro do SketchUp (em vez do navegador) ----
  SPLASH = <<~'HTMLSPLASH'
<div id="pcfSplash" style="position:fixed;inset:0;z-index:100000;display:flex;align-items:center;justify-content:center;background:radial-gradient(ellipse at center,#14213a 0%,#0a0f1c 70%);font-family:'Segoe UI',system-ui,sans-serif;color:#e8f1ff;transition:opacity .45s ease">
<style>
#pcfSplash .sg{position:absolute;inset:0;background-image:linear-gradient(rgba(80,160,255,.07) 1px,transparent 1px),linear-gradient(90deg,rgba(80,160,255,.07) 1px,transparent 1px);background-size:32px 32px;animation:spGrid 6s linear infinite}
@keyframes spGrid{to{background-position:32px 32px}}
#pcfSplash .sc{position:relative;text-align:center;padding:34px 46px;border:1px solid rgba(90,170,255,.35);border-radius:16px;background:rgba(10,20,40,.72);box-shadow:0 0 40px rgba(40,140,255,.25),inset 0 0 30px rgba(40,140,255,.08);min-width:360px}
#pcfSplash svg{display:block;margin:0 auto 14px}
#pcfSplash .r1{transform-origin:60px 60px;animation:spGira 1.6s linear infinite}
#pcfSplash .r2{transform-origin:60px 60px;animation:spGira 2.6s linear infinite reverse}
#pcfSplash .r3{transform-origin:60px 60px;animation:spPulsa 1.6s ease-in-out infinite}
@keyframes spGira{to{transform:rotate(360deg)}}
@keyframes spPulsa{0%,100%{opacity:.35;transform:scale(.92)}50%{opacity:1;transform:scale(1.04)}}
#pcfSplash h1{margin:0;font-size:26px;letter-spacing:6px;font-weight:700;background:linear-gradient(90deg,#5fb4ff,#c8e6ff,#ff4d6d);-webkit-background-clip:text;background-clip:text;color:transparent}
#pcfSplash .st{margin:8px 0 16px;font-size:13px;letter-spacing:1px;color:#9fc3ee;min-height:18px}
#pcfSplash .bar{height:4px;border-radius:4px;background:rgba(95,180,255,.15);overflow:hidden;position:relative}
#pcfSplash .bar i{position:absolute;top:0;left:-40%;width:40%;height:100%;background:linear-gradient(90deg,transparent,#5fb4ff,#ff4d6d,transparent);animation:spBar 1.2s ease-in-out infinite}
@keyframes spBar{to{left:100%}}
#pcfSplash .v{margin-top:12px;font-size:10px;letter-spacing:2px;color:#5d7aa3}
</style>
<div class="sg"></div>
<div class="sc">
<svg width="120" height="120" viewBox="0 0 120 120">
<circle class="r2" cx="60" cy="60" r="52" fill="none" stroke="#2c5d99" stroke-width="2" stroke-dasharray="6 10"/>
<circle class="r1" cx="60" cy="60" r="42" fill="none" stroke="url(#spG)" stroke-width="5" stroke-linecap="round" stroke-dasharray="150 120"/>
<g class="r3"><rect x="40" y="36" width="40" height="48" rx="3" fill="none" stroke="#9fd0ff" stroke-width="2"/><path d="M40 52h40M58 36v48" stroke="#ff4d6d" stroke-width="1.6" stroke-dasharray="3 3"/></g>
<defs><linearGradient id="spG" x1="0" x2="1"><stop offset="0" stop-color="#5fb4ff"/><stop offset="1" stop-color="#ff4d6d"/></linearGradient></defs>
</svg>
<h1>PCF LABEL</h1>
<div class="st" id="pcfSplashTxt">Lendo as peças do SketchUp…</div>
<div class="bar"><i></i></div>
<div class="v">PLANO DE CORTE · ETIQUETAS · G-CODE</div>
</div>
<script>(function(){var t=['Lendo as peças do SketchUp…','Conferindo materiais e cores…','Montando as chapas…','Preparando o plano de corte…'],i=0,e=document.getElementById('pcfSplashTxt');window.__pcfSpT=setInterval(function(){if(!e||!e.isConnected)return clearInterval(window.__pcfSpT);i=(i+1)%t.length;e.textContent=t[i]},1100)})();</script>
</div>
  HTMLSPLASH
  # abre a janela já com a tela de carregamento (aparece na hora, antes de ler as peças)
  def self.splash
    html = "<!doctype html><html><head><meta charset=\"utf-8\"><title>PCF Label</title></head><body style=\"margin:0;background:#0a0f1c\">#{SPLASH}</body></html>"
    if @dlg && @dlg.visible?
      @dlg.set_html(html); @dlg.bring_to_front
    else
      @dlg = UI::HtmlDialog.new(dialog_title: 'PCF Label - plano de corte', preferences_key: 'PCFLabel.tela', scrollable: true,
                                resizable: true, width: 1400, height: 900, style: UI::HtmlDialog::STYLE_DIALOG)
      callbacks(@dlg)
      @dlg.set_on_closed { (restaurar_vista rescue nil); @projeto_externo = nil }   # fechou: volta a valer o projeto aberto
      @dlg.set_html(html)
      @dlg.show
    end
  rescue
    nil
  end
  def self.abrir_tela(arquivo)
    if @dlg && @dlg.visible?
      @dlg.set_file(arquivo); @dlg.bring_to_front; return
    end
    @dlg = UI::HtmlDialog.new(dialog_title: 'PCF Label - plano de corte', preferences_key: 'PCFLabel.tela', scrollable: true,
                              resizable: true, width: 1400, height: 900, style: UI::HtmlDialog::STYLE_DIALOG)
    callbacks(@dlg)
    @dlg.set_on_closed { (restaurar_vista rescue nil); @projeto_externo = nil }   # fechou: volta a valer o projeto aberto
    @dlg.set_file(arquivo)
    @dlg.show
  end

  # grava no grupo do modelo o mesmo número e nome da peça no corte (ex.: "12 - Lateral esquerda")
  # caminho "pid.pid.pid" -> [lista de instâncias, transformação no mundo]
  def self.caminho(ref)
    m = Sketchup.active_model
    ip = (m.instance_path_from_pid_path(ref.to_s) rescue nil)
    if ip && ip.valid?
      return [ip.to_a, ip.transformation]
    end
    e = m.find_entity_by_persistent_id(ref.to_s.split('.').last.to_i)
    e && e.respond_to?(:definition) ? [[e], e.transformation] : nil
  end

  # face principal da peça (maior face) no mundo: [centro, normal]
  def self.face_mundo(inst, t)
    f = inst.definition.entities.grep(Sketchup::Face).max_by(&:area)
    bb = Geom::BoundingBox.new
    inst.definition.entities.grep(Sketchup::Face).each { |x| x.vertices.each { |v| bb.add(v.position.transform(t)) } }
    bb = inst.definition.bounds.then { |b0| b1 = Geom::BoundingBox.new; 8.times { |k| b1.add(b0.corner(k).transform(t)) }; b1 } if bb.empty?
    n = f ? f.normal.transform(t).normalize : Geom::Vector3d.new(0, -1, 0)
    [bb, n]
  end

  ETIQ = 'PCF Nomes'
  # nomes do corte: renomeia os grupos e põe uma etiqueta com o nome na frente de cada peça (camada "PCF Nomes")
  # material escuro do texto 3D
  def self.mat_nome(m)
    mt = m.materials['PCF Nome'] || m.materials.add('PCF Nome')
    mt.color = Sketchup::Color.new(20, 20, 20)
    mt
  end
  def self.mat_fundo_nome(m)
    mt = m.materials['PCF Nome fundo'] || m.materials.add('PCF Nome fundo')
    mt.color = Sketchup::Color.new(255, 255, 255)
    mt
  end

  # número da peça: mesmo tamanho em todas, nos DOIS lados da peça, sempre de pé e legível de quem olha aquele lado.
  # Fica dentro da peça (acompanha se mover), mas a posição é montada no MUNDO e desfeita a escala da peça — não deforma nem espelha.
  NOME_TXT = 35.mm      # altura do número
  NOME_RAIO = 40.mm     # raio do círculo branco
  def self.texto3d(ents, inst, tr, nome, tag, mt, ref, pai_centro = nil)
    d = inst.definition
    fs = d.entities.grep(Sketchup::Face)
    f0 = fs.max_by(&:area)
    return nil unless f0
    m0 = Sketchup.active_model
    cpw = d.bounds.center.transform(tr)
    num = nome.to_s.split(/\s*\+\s*/).map { |pt| pt[/\d+/] }.compact
    txt = num.empty? ? nome.to_s : num.join(' · ')
    # as duas faces grandes (frente e verso)
    cands = fs.select { |x| x.area > f0.area * 0.5 && x.normal.parallel?(f0.normal) }
    lados = []
    todos = []
    cands.each do |x|
      cw = Geom::BoundingBox.new.tap { |b2| x.outer_loop.vertices.each { |v| b2.add(v.position.transform(tr)) } }.center
      nw = x.normal.transform(tr); next if nw.length == 0
      nw.normalize!
      dv = cw - cpw; nw.reverse! if dv.length > 0.1.mm && nw % dv < 0     # normal sempre para fora da peça
      next if lados.any? { |_, n2| n2.samedirection?(nw) }
      todos << [cw, nw] unless todos.any? { |_, n2| n2.samedirection?(nw) }
      # face encostada em outra peça: não põe (ficaria escondido / brigando com a outra)
      r = (m0.raytest([cw.offset(nw, 0.5.mm), nw], true) rescue nil)
      next if r && cw.distance(r[0]) < 3.mm
      lados << [cw, nw]
    end
    # as duas faces encostadas em outras peças: põe mesmo assim (antes ficava escondido no meio da peça e não aparecia)
    lados = todos if lados.empty?
    lados = [[cpw, Geom::Vector3d.new(0, -1, 0)]] if lados.empty?
    feitos = []
    lados.each do |cw, nw|
      xw = Z_AXIS * nw
      xw = Geom::Vector3d.new(1, 0, 0) if xw.length < 0.01      # peça deitada: lê de frente (eixo X)
      xw.normalize!
      yw = (nw * xw).normalize
      g = ents.add_group
      tg = g.entities.add_group
      tg.entities.add_3d_text(txt, TextAlignCenter, 'Arial', true, false, NOME_TXT, 0.0, 0.0, true, 0.0)
      tb = tg.bounds
      k = [1.0, (NOME_RAIO * 1.5) / [tb.width, 0.001].max].min       # número comprido encolhe para caber no círculo
      tg.transform!(Geom::Transformation.scaling(k) * Geom::Transformation.translation(Geom::Vector3d.new(-tb.center.x, -tb.center.y, 0.3.mm)))
      tg.material = mt
      ed = g.entities.add_circle(ORIGIN, Z_AXIS, NOME_RAIO, 48)
      fc = g.entities.add_face(ed)
      if fc
        fc.reverse! if fc.normal.z < 0
        fc.material = mat_fundo_nome(m0); fc.back_material = fc.material
        ed.each { |e2| e2.hidden = true }
      end
      mundo = Geom::Transformation.axes(cw.offset(nw, 0.4.mm), xw, yw, nw)
      g.transform!(tr.inverse * mundo)
      g.layer = tag
      g.name = 'PCF Nome'
      g.set_attribute('pcf', 'nome', ref.to_s)
      feitos << g
    end
    feitos
  end

  # botão "ocultar / mostrar números" (entra também quando o plugin se atualiza sozinho, sem reiniciar)
  def self.botao_nomes
    return if $pcf_botao_nomes
    $pcf_botao_nomes = true
    tb = UI.toolbar(PCFLabel::BARRA)
    cn = UI::Command.new('PCF · Números') { PCFLabel.alternar_nomes }
    cn.tooltip = 'PCF · Números'
    cn.status_bar_text = 'Mostrar / ocultar nº das peças'
    cn.set_validation_proc { (l = Sketchup.active_model.layers[PCFLabel::ETIQ]) && !l.visible? ? MF_UNCHECKED : MF_CHECKED }
    PCFLabel.por_icone(cn, 'numeros', 'pcf_nomes.png')
    tb.add_item(cn); tb.show
    UI.menu('Extensions').add_item(cn)
  end

  # botão "Detalhamento": cria as cenas e monta o LayOut no padrão Zonta
  def self.botao_detalhamento
    return if $pcf_botao_det
    $pcf_botao_det = true
    # (sem botão na barra: o Detalhamento fica no painel PCF · LayOut e no menu Extensões)
    cd = UI::Command.new('PCF · Detalhamento') { PCFLabel.detalhar }
    cd.tooltip = 'PCF · Detalhamento'
    cd.status_bar_text = 'Cenas · LayOut · PDF'
    PCFLabel.por_icone(cd, 'detalhamento', 'pcf_det.png')
    UI.menu('Extensions').add_item(cd)
  end
  def self.detalhar
    f = File.join(__dir__, 'detalhamento.rb')
    return UI.messagebox('Falta o arquivo detalhamento.rb do PCF Label. Reinstale o plugin.') unless File.exist?(f)
    load f
    unless defined?(Layout::Document)
      return UI.messagebox('Para gerar o LayOut precisa do SketchUp Pro (com LayOut).')
    end
    r = UI.messagebox("Gerar o detalhamento deste projeto?\n\n• cria as cenas das paredes (PCF D…)\n• monta o LayOut no padrão Zonta e salva o PDF na pasta Projeto Tecnico\n\nPode levar alguns minutos.", MB_YESNO)
    return unless r == IDYES
    UI.start_timer(0.2, false) { PCFLabel::Detalhar.gerar }
  end

  def self.alternar_nomes
    # com o PCF Ferramentas: menu com mostrar/ocultar todos, ocultar um grupo ou deixar só um grupo
    return PCF::Ferramentas.numeros_menu if defined?(PCF::Ferramentas) && PCF::Ferramentas.respond_to?(:numeros_menu)
    m = Sketchup.active_model
    l = m.layers[ETIQ]
    return UI.messagebox('Ainda não tem números nas peças. Gere o plano no PCF Label primeiro.') unless l
    m.start_operation('PCF: ocultar/mostrar números', true)
    l.visible = !l.visible?
    m.commit_operation
  end

  # números das peças em pé alinhados na MESMA altura, por móvel (peças com alturas que se cruzam);
  # e o número sempre em cima da peça de verdade (peça com recorte: procura um ponto que esteja na chapa)
  def self.alinhar_nomes(m)
    em_pe = []
    busca = lambda do |ents, t|
      ents.each do |e|
        next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        if e.name == 'PCF Nome'
          tw = t * e.transformation
          em_pe << { g: e, t: t, o: tw.origin, n: tw.zaxis, x: tw.xaxis, ref: e.get_attribute('pcf', 'nome').to_s } if tw.zaxis.z.abs < 0.1
        else
          busca.(e.definition.entities, t * e.transformation)
        end
      end
    end
    busca.(m.entities, Geom::Transformation.new)
    em_pe.each do |h|
      c = caminho(h[:ref]); next unless c
      h[:inst] = c[0].last; h[:tr] = c[1]
      bw = Geom::BoundingBox.new; h[:inst].definition.bounds.then { |b0| 8.times { |k| bw.add(b0.corner(k).transform(c[1])) } }
      h[:z0] = bw.min.z; h[:z1] = bw.max.z
    end
    em_pe.select! { |h| h[:inst] }
    # o ponto (e o círculo em volta) está em cima da chapa?
    na_chapa = lambda do |h, p|
      inv = h[:tr].inverse
      fs = h[:inst].definition.entities.grep(Sketchup::Face)
      nl = h[:n].transform(inv); next false if nl.length == 0
      fs = fs.select { |f| f.normal.parallel?(nl) && f.area > 100.mm * 100.mm }
      up = Geom::Vector3d.new(0, 0, 1)
      [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]].all? do |dx, dz|
        q = p.offset(h[:x], dx * (NOME_RAIO + 5.mm)).offset(up, dz * (NOME_RAIO + 5.mm)).transform(inv)
        fs.any? { |f| pp = q.project_to_plane(f.plane); [Sketchup::Face::PointInside, Sketchup::Face::PointOnEdge].include?(f.classify_point(pp)) }
      end
    end
    # agrupa por móvel: peças cujas alturas se cruzam e que estão perto
    grupos = []
    em_pe.sort_by { |h| h[:z0] }.each do |h|
      gr = grupos.find { |gg| gg.any? { |k| [h[:z1], k[:z1]].min - [h[:z0], k[:z0]].max > 100.mm && h[:o].distance(k[:o]) < 3000.mm } }
      gr ? gr << h : grupos << [h]
    end
    grupos.each do |gr|
      zs = gr.map { |h| (h[:z0] + h[:z1]) / 2 }.sort
      alvo = zs[zs.size / 2]
      gr.each do |h|
        lo = h[:z0] + NOME_RAIO + 15.mm; hi = h[:z1] - NOME_RAIO - 15.mm
        # a peça não chega na altura comum: número no meio dela
        z = (lo > hi || alvo < lo || alvo > hi) ? (h[:z0] + h[:z1]) / 2 : alvo
        # se ali não tem chapa (recorte), anda para cima/baixo até achar
        p = Geom::Point3d.new(h[:o].x, h[:o].y, z)
        unless na_chapa.(h, p)
          ok = nil
          (1..80).each do |k|
            [1, -1].each { |sg| zz = z + sg * k * 20.mm; next if zz < lo || zz > hi; pq = Geom::Point3d.new(h[:o].x, h[:o].y, zz); (ok = pq; break) if na_chapa.(h, pq) }
            break if ok
          end
          p = ok || h[:o]
        end
        dz = p.z - h[:o].z
        next if dz.abs < 0.5.mm
        h[:g].transform!(Geom::Transformation.translation(Geom::Vector3d.new(0, 0, dz).transform(h[:t].inverse)))
      end
    end
  end

  # nº no NOME do Dinabox (campo "Nome" = db01), que é o que sai na etiqueta/relatório do Dinabox: "64 - Tamponamento".
  # A peça que tem o campo Nome recebe nele; tamponamento (módulo de 1 peça) recebe no módulo.
  def self.nome_dinabox(cam, num)
    tem = ->(o) { o && o.respond_to?(:definition) && (o.definition.get_attribute('dynamic_attributes', '_db01_formula') || o.definition.get_attribute('dynamic_attributes', 'db01') || o.get_attribute('dynamic_attributes', 'db01')) }
    p = cam.last
    alvo = tem.(p) ? p : nil
    if !alvo && cam.size > 1
      mod = cam[-2]
      pc = mod.definition.entities.count { |x| x.respond_to?(:definition) && x.definition.name =~ /\Adinabox_peca_/i }
      alvo = mod if tem.(mod) && pc == 1
    end
    return nil unless alvo
    atual = (alvo.get_attribute('dynamic_attributes', 'db01') || alvo.definition.get_attribute('dynamic_attributes', 'db01')).to_s
    base = atual.sub(/\A\d+\s*-\s*/, '').strip
    novo = base.empty? ? num.to_s : "#{num} - #{base}"
    obs = [alvo]; obs << alvo.definition if alvo.definition.count_instances == 1
    obs.each do |o|
      o.set_attribute('dynamic_attributes', 'db01', novo)
      o.set_attribute('dynamic_attributes', '_db01_formula', novo.inspect)
      o.set_attribute('dynamic_attributes', 'name', novo) if o.get_attribute('dynamic_attributes', 'name') || o.is_a?(Sketchup::ComponentDefinition)
      # o Dinabox exporta o nome pelo texto "dinabox_dados" ([P]código#NOME#…): troca ali também
      dd = o.get_attribute('dynamic_attributes', 'dinabox_dados').to_s
      if dd.start_with?('[P]') && (pt = dd.split('#', -1)).size >= 3
        pt[1] = novo; o.set_attribute('dynamic_attributes', 'dinabox_dados', pt.join('#'))
      end
    end
    # tamponamento: o nome está no módulo, mas o texto que o Dinabox exporta é o da peça
    unless alvo == p
      [p, p.definition].each do |o|
        dd = o.get_attribute('dynamic_attributes', 'dinabox_dados').to_s
        next unless dd.start_with?('[P]') && (pt = dd.split('#', -1)).size >= 3
        pt[1] = novo; o.set_attribute('dynamic_attributes', 'dinabox_dados', pt.join('#'))
      end
    end
    novo
  end

  def self.renomear(mapa)
    m = Sketchup.active_model
    m.start_operation('PCF: nomes do corte', true, false, true)
    tag = m.layers[ETIQ] || m.layers.add(ETIQ)
    mt = mat_nome(m)
    # tira os nomes antigos (texto com seta ou texto 3D), no modelo e dentro das peças
    # tira só os números das peças DESTE plano (os das peças de outros planos continuam)
    refs = mapa.keys.map(&:to_s)
    limpa = ->(ents) { vv = ents.select { |x| (x.is_a?(Sketchup::Text) || x.is_a?(Sketchup::Group) || x.is_a?(Sketchup::ComponentInstance)) && refs.include?(x.get_attribute('pcf', 'nome').to_s) }; ents.erase_entities(vv) unless vv.empty? }
    limpa.(m.entities)
    m.definitions.each { |d| limpa.(d.entities) unless d.image? }
    n = 0
    mapa.each do |ref, nome|
      c = caminho(ref)
      next unless c
      e = c[0].last
      # peça que já está num grupo do PCF Ferramentas: fica só com o número do grupo (uma peça = um número)
      next if e.get_attribute('pcf', 'grupo')
      if e.respond_to?(:name=) && e.name != nome then e.name = nome; n += 1 end
      # peça do Dinabox: o nº também no Nome do Dinabox (sai na etiqueta dele)
      (nome_dinabox(c[0], nome.to_s[/\d+/]) if nome.to_s[/\d+/] && c[0].any? { |x| dinabox?(x, x.definition) }) rescue nil
      begin
        pc = nil
        if c[0].length > 1
          tp = Geom::Transformation.new; c[0][0..-2].each { |x| tp = tp * x.transformation }
          bp = Geom::BoundingBox.new; c[0][-2].definition.bounds.then { |b0| 8.times { |k| bp.add(b0.corner(k).transform(tp)) } }
          pc = bp.center
        end
        # peça do Dinabox: o número NUNCA fica dentro dela (o Dinabox lê tudo que está dentro como usinagem e dá erro)
        dentro_db = c[0].any? { |x| dinabox?(x, x.definition) }
        if e.definition.count_instances == 1 && !dentro_db
          texto3d(e.definition.entities, e, c[1], nome, tag, mt, ref, pc)
        else
          # componente repetido ou peça do Dinabox: o texto fica no modelo, na posição desta cópia
          (texto3d(e.definition.entities, e, c[1], nome, tag, mt, ref, pc) || []).each do |g|
            gw = m.entities.add_instance(g.definition, c[1] * g.transformation)
            gw.material = mt; gw.layer = tag; gw.name = 'PCF Nome'; gw.set_attribute('pcf', 'nome', ref.to_s)
            g.erase!
          end
        end
      rescue StandardError => er
        puts "PCF nome #{nome}: #{er.message}"
        (log_atu("ERRO número 3D #{nome}: #{er.message} @ #{er.backtrace.to_a.first}") rescue nil)
      end
    end
    (alinhar_nomes(m) rescue nil)
    m.commit_operation
    n
  end

  # gera PDFs (etiquetas no tamanho exato, lista de corte em A4) com o Chrome/Edge sem janela — ~1 s — e salva na pasta do projeto
  def self.navegador_pdf
    ['C:/Program Files/Google/Chrome/Application/chrome.exe', 'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
     File.join(ENV['LOCALAPPDATA'].to_s, 'Google/Chrome/Application/chrome.exe'),
     'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe', 'C:/Program Files/Microsoft/Edge/Application/msedge.exe'].find { |x| File.exist?(x) }
  end

  def self.gerar_pdfs(arquivos)
    nav = navegador_pdf
    raise 'Chrome ou Edge não encontrado' unless nav
    mp = Sketchup.active_model.path.to_s
    pasta = mp.empty? ? File.join(ENV['USERPROFILE'].to_s, 'Documents') : File.dirname(mp)
    tmpd = ENV['TEMP'] || Dir.tmpdir
    perfil = File.join(tmpd, 'PCF chrome pdf')
    feitos = []
    arquivos.each_with_index do |o, i|
      nome = o['nome'].to_s.gsub(/[\\\/:*?"<>|]/, '_')
      pdf = File.join(pasta, nome + '.pdf')
      # se o PDF antigo estiver aberto (travado), salva com outro nome
      if File.exist?(pdf)
        begin; File.delete(pdf); rescue; pdf = File.join(pasta, "#{nome} (#{Time.now.strftime('%H%M%S')}).pdf"); end
      end
      tmp = File.join(tmpd, "PCF pdf #{i}.html")
      File.binwrite(tmp, o['html'].to_s.b)
      system(nav, '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--disable-extensions',
             '--no-pdf-header-footer', "--user-data-dir=#{perfil}", "--print-to-pdf=#{pdf.tr('/', '\\')}",
             'file:///' + tmp.tr('\\', '/').gsub(' ', '%20'))
      feitos << pdf if File.exist?(pdf) && File.size(pdf) > 0
    end
    if feitos.empty?
      msg = '⚠ Não consegui gerar os PDFs.'
    else
      msg = "✔ PDFs salvos na pasta do projeto: " + feitos.map { |f| File.basename(f) }.join(' · ')
      UI.openURL('file:///' + feitos.first.tr('\\', '/').gsub(' ', '%20'))
    end
    @dlg.execute_script("if($('cncMsg')){$('cncMsg').className='hint #{feitos.empty? ? 'erro' : 'ok'}';$('cncMsg').textContent=#{msg.to_json}}") rescue nil
    feitos
  end

  # mostra a peça: abre a peça (o resto fica esmaecido) e procura um ângulo onde nada fique na frente dela, com zoom no tamanho dela
  # peça repetida (componente com cópias): o número fica fora dela, e some quando a peça é aberta pelo plano.
  # Este desenho mostra o número por cima enquanto a peça estiver aberta.
  if defined?(Sketchup::Overlay)
    class NumeroAberto < Sketchup::Overlay
      attr_accessor :alvo
      def initialize; super('pcf.numero_aberto', 'PCF Label: número da peça aberta'); @alvo = nil end
      def draw(view)
        return unless @alvo
        inst, pts, txt = @alvo
        ap = view.model.active_path
        return unless ap && ap.last == inst
        pts.each do |p, n|
          next if (view.camera.eye - p) % n <= 0        # só o lado virado para quem olha
          q = view.screen_coords(p)
          r = [[view.pixels_to_model(1, p) > 0 ? NOME_RAIO / view.pixels_to_model(1, p) : 14, 9].max, 60].min
          circ = (0..36).map { |k| a = k * Math::PI / 18; Geom::Point3d.new(q.x + r * Math.cos(a), q.y + r * Math.sin(a), 0) }
          view.drawing_color = 'white'; view.draw2d(GL_POLYGON, circ)
          view.drawing_color = Sketchup::Color.new(20, 20, 20); view.line_width = 1.5; view.draw2d(GL_LINE_STRIP, circ)
          view.draw_text(Geom::Point3d.new(q.x, q.y - r * 0.55, 0), txt, size: (r * 0.75).round, bold: true, align: TextAlignCenter, color: Sketchup::Color.new(20, 20, 20))
        end
      end
    end
  end
  # contorno de um recorte (furo/rebaixo) desenhado por cima de tudo, em vermelho piscando
  if defined?(Sketchup::Overlay)
    class DestaqueRecorte < Sketchup::Overlay
      attr_accessor :alvo
      def initialize; super('pcf.destaque_recorte', 'PCF Label: recorte destacado'); @alvo = nil end
      def draw(view)
        return unless @alvo
        pts, txt = @alvo
        view.line_stipple = ''
        view.drawing_color = Sketchup::Color.new(255, 255, 255); view.line_width = 9
        view.draw2d(GL_LINE_LOOP, pts.map { |p| view.screen_coords(p) })
        view.drawing_color = Sketchup::Color.new(230, 0, 60); view.line_width = 5
        view.draw2d(GL_LINE_LOOP, pts.map { |p| view.screen_coords(p) })
        c = Geom::Point3d.new(pts.sum(&:x) / pts.size, pts.sum(&:y) / pts.size, pts.sum(&:z) / pts.size)
        q = view.screen_coords(c)
        view.draw_text(Geom::Point3d.new(q.x, q.y - 9, 0), txt, size: 13, bold: true, align: TextAlignCenter, color: Sketchup::Color.new(230, 0, 60))
      end
    end
  end
  def self.destacar_recorte(base, tipo, idx)
    return unless defined?(DestaqueRecorte)
    m = Sketchup.active_model
    c = caminho(base)
    return unless c
    lista, t = c
    inst = lista.last
    pecas = []
    coletar([inst], t * inst.transformation.inverse, [], pecas)
    r = (@rec3 || {})[inst.persistent_id.to_s]
    return unless r
    pts = (r[tipo] || [])[idx - 1]
    return unless pts && pts.size >= 2
    @destaque = nil if @destaque && @destaque_m != m
    unless @destaque
      @destaque = m.overlays.to_a.find { |o| o.overlay_id == 'pcf.destaque_recorte' rescue false }
      unless @destaque then @destaque = DestaqueRecorte.new; m.overlays.add(@destaque) end
      @destaque_m = m
    end
    @destaque.enabled = true rescue nil
    @destaque.alvo = [pts, "#{tipo == 'f' ? 'FURO' : 'REBAIXO'} #{idx}"]
    m.active_view.invalidate
  end

  def self.overlay_numero(inst, lista_t, ref)
    return unless defined?(NumeroAberto)
    m = Sketchup.active_model
    @ov = nil if @ov && @ov_modelo != m
    unless @ov
      @ov = m.overlays.to_a.find { |o| o.overlay_id == 'pcf.numero_aberto' rescue false }
      unless @ov then @ov = NumeroAberto.new; m.overlays.add(@ov) end
      @ov_modelo = m
    end
    @ov.enabled = true rescue nil
    # só quando o número dessa peça está fora dela (peça repetida)
    dentro = inst.definition.entities.any? { |x| x.respond_to?(:name) && x.name == 'PCF Nome' }
    if dentro then @ov.alvo = nil; return end
    pts = []
    m.entities.each { |x| next unless x.respond_to?(:name) && x.name == 'PCF Nome' && x.get_attribute('pcf', 'nome').to_s == ref.to_s
      pts << [x.transformation.origin, x.transformation.zaxis] }
    num = (inst.name.to_s[/\d+/] || '')
    @ov.alvo = pts.empty? ? nil : [inst, pts, num]
  rescue
    nil
  end

  # grava os arquivos .tap (G-code) na pasta que o Paulo escolher; lembra a última pasta
  def self.salvar_taps(json)
    o = JSON.parse(json.to_s.dup.force_encoding('UTF-8'))
    arqs = o['arquivos'] || []
    ini = Sketchup.read_default('PCFLabel', 'pasta_tap', '').to_s
    if ini.empty? || !Dir.exist?(ini)
      mp = Sketchup.active_model.path.to_s
      ini = mp.empty? ? File.join(ENV['USERPROFILE'] || '', 'Desktop') : File.dirname(mp)
    end
    pasta = UI.select_directory(title: 'Onde salvar os arquivos .tap?', directory: ini)
    return unless pasta
    Sketchup.write_default('PCFLabel', 'pasta_tap', pasta)
    arqs.each { |a| File.binwrite(File.join(pasta, a['nome'].to_s.gsub(/[\\\/:*?"<>|]/, '_')), a['txt'].to_s.encode('UTF-8').b) }
    @dlg.execute_script("tapSalvos(#{arqs.size}, #{JSON.generate(pasta.tr('/', '\\'))})") if @dlg
    (UI.openURL('file:///' + pasta.tr('\\', '/').gsub(' ', '%20')) rescue nil)
  rescue => e
    (@dlg.execute_script("tapSalvos(0, '', #{JSON.generate(e.message)})") rescue nil) if @dlg
  end

  def self.selecionar(ref)
    # o mesmo pedido chegando 2, 3 vezes seguidas (ligações antigas do SketchUp): faz uma vez só
    agora = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return true if @ult_ref == ref && @ult_ref_t && agora - @ult_ref_t < 1.0
    @ult_ref = ref; @ult_ref_t = agora
    # a tela usa este mesmo canal para salvar o plano e para diagnóstico (funciona mesmo com a tela aberta antes da atualização)
    if ref.start_with?('PLANO:')
      begin; salvar_plano(ref[6..-1]); rescue => e; (File.binwrite(File.join(ENV['APPDATA'], 'PCF Label', 'erro_plano.txt'), e.message.b) rescue nil); end
      return true
    end
    if ref.start_with?('TAP:')
      salvar_taps(ref[4..-1])
      return true
    end
    if ref.start_with?('IMPR:')
      o = JSON.parse(ref[5..-1].dup.force_encoding('UTF-8'))
      arq = File.join(ENV['TEMP'] || Dir.tmpdir, "PCF imprimir - #{o['nome'].to_s.gsub(/[^\w\- ]/, '_')}.html")
      # o mesmo pedido de impressão chegando 2 vezes seguidas abre só UMA aba
      chave = [o['nome'], o['html'].to_s.size, o['html'].to_s.hash]
      return true if @ult_impr && @ult_impr[0] == chave && Time.now - @ult_impr[1] < 8
      @ult_impr = [chave, Time.now]
      File.binwrite(arq, o['html'].to_s.b)
      UI.openURL('file:///' + arq.tr('\\', '/').gsub(' ', '%20'))
      return true
    end
    # configuração da tela (ferramentas, folga, margem, nomes das cores…) igual em todos os PCs
    if ref.start_with?('CFG:')
      begin
        require 'fileutils'; f = File.join(pasta_comum, 'config.json'); FileUtils.mkdir_p(File.dirname(f))
        txt = ref[4..-1].to_s.dup.force_encoding('UTF-8')
        txt = juntar_cfg(f, txt)
        File.binwrite(f, txt.b)
      rescue
        nil
      end
      return true
    end
    if ref.start_with?('CORES:')
      begin; gravar_cores(JSON.parse(ref[6..-1].dup.force_encoding('UTF-8'))); rescue; end
      return true
    end
    if ref.start_with?('PDFS:')
      begin; gerar_pdfs(JSON.parse(ref[5..-1].dup.force_encoding('UTF-8'))['arquivos']); rescue => e; (UI.messagebox("Não consegui gerar os PDFs: #{e.message}") rescue nil); end
      return true
    end
    if ref.start_with?('LOG:')
      begin; f = File.join(pasta_comum, "log_tela_#{(ENV['COMPUTERNAME'] || 'PC')}.txt")
        (File.rename(f, f.sub(/\.txt$/, '_antigo.txt')) rescue nil) if File.exist?(f) && File.size(f) > 300_000   # não deixa o registro crescer sem fim
        File.open(f, 'a:UTF-8') { |io| io.puts ref[4..-1].to_s.dup.force_encoding('UTF-8') }; rescue; end
      return true
    end
    if ref == 'ATUALIZAR' then UI.start_timer(0.1, false) { aplicar_atualizacao }; return true end
    if ref == 'PLANO_ZERAR' then UI.start_timer(0.1, false) { zerar_planos }; return true end
    if ref.start_with?('PLANO_EXCLUIR_CONF:') then h = (JSON.parse(ref.sub('PLANO_EXCLUIR_CONF:', '')) rescue {}); UI.start_timer(0.1, false) { plano_excluir_conf(h) }; return true end
    if ref.start_with?('HIST_EXCLUIR:') then h = (JSON.parse(ref.sub('HIST_EXCLUIR:', '')) rescue {}); UI.start_timer(0.1, false) { hist_excluir(h) }; return true end
    if ref.start_with?('PLANO_EXCLUIR:') then UI.start_timer(0.1, false) { id0 = ref.sub('PLANO_EXCLUIR:', ''); gerado_obj?(ler_plano(id0)) ? (UI.messagebox('Plano gerado (G-code já feito): exclua pela lista de planos, com a senha da conta.') rescue nil) : excluir_plano(id0) }; return true end
    if ref.start_with?('PLANO_ABRIR:') then UI.start_timer(0.1, false) { abrir_plano(ref.sub('PLANO_ABRIR:', '')) }; return true end
    # plano novo e lista de planos: lê de novo o que está visível AGORA (não o da hora que abriu a tela)
    if ref == 'PLANO_ULTIMO' then UI.start_timer(0.1, false) { abrir_ultimo_plano }; return true end
    if ref == 'TELA_RECARREGAR' then UI.start_timer(0.1, false) { recarregar_seguro }; return true end
    if ref == 'PLANO_CLIENTES' then UI.start_timer(0.1, false) { nuvem_listar }; return true end
    if ref.start_with?('PLANO_NUVEM_EXCLUIR:') then h = (JSON.parse(ref.sub('PLANO_NUVEM_EXCLUIR:', '')) rescue {}); UI.start_timer(0.1, false) { nuvem_excluir(h) }; return true end
    if ref.start_with?('PLANO_NUVEM:') then UI.start_timer(0.1, false) { nuvem_abrir(ref.sub('PLANO_NUVEM:', '')) }; return true end
    if ref.start_with?('PROJETO_ABRIR:') then k, skp = ref.sub('PROJETO_ABRIR:', '').split('|', 2); UI.start_timer(0.1, false) { abrir_projeto_lista(k, skp) }; return true end
    if ref == 'CONTA_LOGIN' then UI.start_timer(0.1, false) { f = conta_pcf; f ? f.conta_janela : UI.messagebox('O login ainda não está instalado neste PC. Atualize o PCF Ferramentas (⬆).') }; return true end
    if ref == 'PLANO_PRINCIPAL' then UI.start_timer(0.1, false) { (@excluidos ||= []).delete(nome_plano); d = copia(@dados_vivos); d[:planoId] = 'principal'; d[:planoNome] = 'Plano principal'; d[:planoEscolhido] = true; d[:planos] = listar_planos; mostrar(d) }; return true end
    if ref == 'PLANO_NOVO' then UI.start_timer(0.1, false) { @pedido_novo = true; enviar(true) }; return true end
    if ref == 'PLANO_LISTA' then UI.start_timer(0.1, false) { enviar(true) }; return true end
    if ref == 'HIST'
      h = File.join(pasta_planos, 'historico')
      arqs = Dir.glob(File.join(h, '*.json').tr('\\', '/')).select { |x| File.basename(x).start_with?((@externo ? @externo[:chave] : nome_plano) + sufixo_plano(@plano_id) + ' ') }.sort_by { |x| File.mtime(x) }.last(60)
      lista = arqs.map { |x| t = File.binread(x).force_encoding('UTF-8'); { arq: File.basename(x), quando: File.mtime(x).strftime('%d/%m %H:%M'), txt: t, gerado: gerado_obj?((JSON.parse(t) rescue nil)) } }
      @dlg.execute_script("receberVersoes(#{JSON.generate(lista).gsub('</', '<\\/')})") rescue nil
      return true
    end
    if ref.start_with?('DIAG')
      File.binwrite(File.join(ENV['APPDATA'], 'PCF Label', 'diag.json'), ref[4..-1].to_s.b) rescue nil
      return true
    end
    # recorte dentro da peça (#f1 = furo 1, #r2 = rebaixo 2): mostra a peça e destaca SÓ esse recorte
    if (rec = ref.to_s[/#([fr])(\d+)\z/])
      base = ref.to_s.sub(/#[fr]\d+\z/, '')
      ok = selecionar(base)
      destacar_recorte(base, rec[1], rec[2..].to_i) rescue nil
      return ok
    end
    (@destaque.alvo = nil rescue nil) if @destaque
    m = Sketchup.active_model
    c = caminho(ref)
    return false unless c
    lista, t = c
    inst = lista.last
    bb, nv = face_mundo(inst, t)
    centro = bb.center
    if lista.length > 1
      tp = Geom::Transformation.new
      lista[0..-2].each { |x| tp = tp * x.transformation }
      bp = Geom::BoundingBox.new; lista[-2].definition.bounds.then { |b0| 8.times { |k| bp.add(b0.corner(k).transform(tp)) } }
      nv.reverse! if (centro - bp.center) % nv < 0 && (centro - bp.center).length > 1.mm
    end
    nv.reverse! if nv.z.abs > 0.9 && nv.z < 0
    v = m.active_view
    fov = (v.camera.fov rescue 35.0).to_f
    fov = 35.0 if fov <= 1 || fov > 120
    tam = [bb.width, bb.height, bb.depth].max
    dist = tam / 2.0 / Math.tan(fov * Math::PI / 360.0) * 1.25
    amostras = [centro] + (0..7).map { |k| q = bb.corner(k); Geom::Point3d.new(centro.x + (q.x - centro.x) * 0.6, centro.y + (q.y - centro.y) * 0.6, centro.z + (q.z - centro.z) * 0.6) }
    vec = ->(a, b2, c2) { Geom::Vector3d.new(a, b2, c2) }
    base = [nv, nv.reverse]
    inclin = [[0, -0.35, 0.3], [0, 0, 0], [0.35, -0.2, 0.25], [-0.35, -0.2, 0.25], [0, 0.35, 0.3], [0, -0.3, -0.3]]
    cands = base.flat_map { |n| inclin.map { |dx, dy, dz| vec.(n.x + dx, n.y + dy, n.z + dz) } } +
            [vec.(0, 0, 1), vec.(0, -1, 0.4), vec.(0.6, -0.6, 0.5), vec.(-0.6, -0.6, 0.5), vec.(0, 1, 0.4), vec.(1, 0, 0.3), vec.(-1, 0, 0.3)]
    melhor = nil
    cands.each do |d|
      next if d.length < 0.01
      d = d.normalize
      olho = centro.offset(d, dist)
      vis = amostras.count do |pt|
        r = m.raytest([olho, pt - olho], true) rescue nil
        r && r[1].include?(inst)
      end
      melhor = [vis, d] if melhor.nil? || vis > melhor[0]
      break if vis == amostras.size
    end
    d = melhor[1]
    olho = centro.offset(d, dist)
    cima = Geom::Vector3d.new(0, 0, 1)
    up = d.parallel?(cima) ? Geom::Vector3d.new(0, 1, 0) : cima
    ro = m.rendering_options
    if melhor[0] == 0
      # nenhum ângulo livre: esconde o resto do modelo enquanto a peça estiver aberta
      @esconder_antes = ro['InactiveHidden'] if @esconder_antes.nil?
      ro['InactiveHidden'] = true
    elsif !@esconder_antes.nil?
      ro['InactiveHidden'] = @esconder_antes; @esconder_antes = nil
    end
    begin
      m.active_path = lista
    rescue
      m.active_path = (lista.length > 1 ? lista[0..-2] : nil) rescue nil
    end
    m.selection.clear
    # a peça e a etiqueta com o nome dela ficam selecionadas juntas
    if m.active_path && m.active_path.last == inst
      m.selection.add(m.active_entities.to_a)
    else
      m.selection.add(inst) rescue nil
    end
    overlay_numero(inst, t, ref)
    cam = Sketchup::Camera.new(olho, centro, up)
    cam.perspective = true
    cam.fov = fov
    v.camera = cam
    v.invalidate
    melhor[0]
  end

  # vigia: quando a tela (etiquetas.html) ou o próprio plugin forem atualizados, recarrega a tela aberta sozinho (o plano fica salvo)
  ARQ_PLUGIN = __FILE__
  def self.iniciar_vigia
    @mt_plugin ||= (File.mtime(ARQ_PLUGIN) rescue nil)
    @mt_tela ||= (File.mtime(MODELO_TELA) rescue nil)
    # tela aberta antes desta versão: pega os dados do próprio arquivo da tela
    unless @dados_json
      arq = Dir.glob(File.join((ENV['TEMP'] || Dir.tmpdir).tr('\\', '/'), 'PCF SketchUp - *.html')).max_by { |x| File.mtime(x) }
      if arq
        m = File.read(arq, encoding: 'UTF-8').match(/const D = (.*?);\r?\nconst VERSAO/m)
        if m then @dados_json = m[1]; @saida ||= arq end
      end
    end
    return if @vigia
    @vigia = UI.start_timer(4, true) { (PCFLabel.vigiar rescue nil) }
  end

  # plano de corte salvo em ARQUIVO: ao lado do .skp (Projeto.pcfplano.json) + cópia e histórico em %APPDATA%\PCF Label\planos
  def self.pasta_planos
    d = File.join(ENV['APPDATA'] || Dir.tmpdir, 'PCF Label', 'planos')
    FileUtils.mkdir_p(File.join(d, 'historico')) rescue nil
    d
  end
  # projeto cujo plano está aberto: o do SketchUp, ou outro (aberto pela página inicial, sem o .skp aberto)
  def self.caminho_projeto
    (@projeto_externo || Sketchup.active_model.path).to_s
  end
  def self.nome_plano
    m = Sketchup.active_model
    t = (@projeto_externo ? File.basename(@projeto_externo, '.*') : (m.title.to_s.empty? ? 'sem nome' : m.title.to_s)).gsub(/[\\\/:*?"<>|]/, '_')
    # dois projetos com o MESMO nome em pastas diferentes (ex.: "Projeto Técnico 01.skp" de clientes diferentes) não podem
    # dividir o mesmo arquivo de plano: o nome leva um código da pasta do projeto
    pth = caminho_projeto
    return t if pth.empty?
    require 'digest/md5'
    "#{t} ##{Digest::MD5.hexdigest(pth.downcase.tr('\\', '/'))[0, 6]}"
  end
  # ---- vários planos no mesmo projeto: "principal" (o de sempre) e Plano 2, 3… (cada um com as próprias peças) ----
  def self.id_plano(id) t = id.to_s.strip; (t.empty? || t == 'principal') ? 'principal' : t.gsub(/[^\w\-]/, '_') end
  def self.sufixo_plano(id) id_plano(id) == 'principal' ? '' : ".#{id_plano(id)}" end
  def self.arq_plano_modelo(id = 'principal')
    pth = caminho_projeto
    pth.empty? ? nil : File.join(File.dirname(pth), File.basename(pth, '.*') + '.pcfplano' + sufixo_plano(id) + '.json')
  end
  def self.salvar_plano(txt)
    require 'fileutils'
    txt = txt.to_s.dup.force_encoding('UTF-8')
    return if txt.strip.empty?
    return salvar_plano_externo(txt) if @externo
    obj = (JSON.parse(txt) rescue nil)
    id = id_plano((obj && obj['id']) || @plano_id)
    return if (@excluidos ||= []).include?(nome_plano + sufixo_plano(id))   # plano excluído: a tela não grava ele de volta
    if obj
      obj['id'] = id; obj['nome'] ||= @plano_nome
      # o plano guarda as próprias peças: abre igual mesmo se depois você esconder/mostrar coisas no SketchUp
      obj['pecas'] ||= JSON.parse(JSON.generate(@dados_atual[:pecas])) if @dados_atual && @dados_atual[:pecas]
      txt = JSON.generate(obj)
    end
    pd = pasta_planos; suf = sufixo_plano(id)
    # segurança: se o plano salvo tinha OUTRAS peças, guarda uma cópia dele antes de gravar por cima (nunca perde um plano)
    begin
      ant_f = File.join(pd, nome_plano + suf + '.json')
      if File.exist?(ant_f) && obj
        ant = JSON.parse(File.read(ant_f, encoding: 'UTF-8'))
        ida = (ant['pecas'] || []).map { |p| p['id'] }.sort; idn = (obj['pecas'] || []).map { |p| p['id'] }.sort
        if ida != idn || ant['n'].to_i != obj['n'].to_i
          h0 = File.join(pd, 'historico'); FileUtils.mkdir_p(h0)
          FileUtils.cp(ant_f, File.join(h0, nome_plano + suf + ' ' + Time.now.strftime('%Y-%m-%d %H-%M-%S') + ' (antes de mudar).json'))
        end
      end
    rescue
      nil
    end
    File.binwrite(File.join(pd, nome_plano + suf + '.json'), txt.b)
    a = arq_plano_modelo(id)
    (File.binwrite(a, txt.b) rescue nil) if a
    (nuvem_enfileirar(nome_plano, id, obj, txt, caminho_projeto) rescue nil) if obj   # o projeto DO PLANO (aberto de outro projeto também)   # ☁ lista de clientes/OSs na conta
    (indice_atualizar_projeto(caminho_projeto) rescue nil)
    # histórico: uma cópia a cada 5 min, guarda as 40 últimas
    h = File.join(pd, 'historico')
    ult = Dir.glob(File.join(h, '*.json')).select { |x| File.basename(x).start_with?(nome_plano + suf + ' ') }.max_by { |x| File.mtime(x) }
    if ult.nil? || Time.now - File.mtime(ult) > 300
      File.binwrite(File.join(h, nome_plano + suf + ' ' + Time.now.strftime('%Y-%m-%d %H-%M') + '.json'), txt.b)
      Dir.glob(File.join(h, '*.json')).sort_by { |x| File.mtime(x) }[0...-300].to_a.each { |x| File.delete(x) rescue nil }
    end
  end
  def self.ler_plano(id = 'principal')
    require 'fileutils'
    suf = sufixo_plano(id)
    cands = [arq_plano_modelo(id), File.join(pasta_planos, nome_plano + suf + '.json')].compact.select { |x| File.exist?(x) }
    return nil if cands.empty?
    # vale o de conteúdo mais NOVO (hora gravada dentro do plano), não o arquivo mexido por último:
    # o arquivo ao lado do projeto (Dropbox) traz o que foi feito no outro PC
    os = cands.map { |x| (JSON.parse(File.read(x, encoding: 'UTF-8')) rescue nil) }.compact
    os.max_by { |o| o['t'].to_i }
  end
  # data e hora em que o plano foi criado: a gravada nele; plano antigo (sem ela) = quando o arquivo dele foi criado
  def self.criado_de(o, arqs)
    c = o.is_a?(Hash) ? o['criado'].to_s : ''
    t = arqs.compact.select { |x| File.exist?(x) }.map { |x| File.ctime(x) rescue nil }.compact.min
    c = t.strftime('%d/%m/%Y %H:%M') if c.empty? && t
    ct = (begin; d, h = c.split(' '); dd, mm, aa = d.split('/').map(&:to_i); hh, mi = h.to_s.split(':').map(&:to_i); Time.new(aa > 0 ? aa : Time.now.year, mm, dd, hh || 0, mi || 0).to_i; rescue; (t ? t.to_i : 0); end)
    [c, ct]
  end
  def self.listar_planos
    pth = caminho_projeto
    ids = []
    unless pth.empty?
      base = File.basename(pth, '.*') + '.pcfplano'
      Dir.children(File.dirname(pth)).each { |n| next unless n.start_with?(base) && n.end_with?('.json'); meio = n[base.size...-5]; ids << (meio.empty? ? 'principal' : meio.sub(/^\./, '')) }
    end
    pd = pasta_planos
    Dir.children(pd).each { |n| next unless n.start_with?(nome_plano) && n.end_with?('.json'); meio = n[nome_plano.size...-5]; ids << (meio.empty? ? 'principal' : meio.sub(/^\./, '')) if meio.empty? || meio.start_with?('.') } rescue nil
    ids.uniq.map do |id|
      o = ler_plano(id); next nil unless o
      cr, ct = criado_de(o, [arq_plano_modelo(id), File.join(pasta_planos, nome_plano + sufixo_plano(id) + '.json')])
      { id: id, nome: o['nome'] || (id == 'principal' ? 'Plano principal' : "Plano #{id}"), data: o['data'], n: o['n'], t: o['t'], criado: cr, ct: ct, gerado: !o['gc'].nil? && o['gc'] != false, salvo: !o['salvo'].to_s.empty?,
        pecas: (o['pecas'] ? o['pecas'].count { |p| !p['dentro'] } : nil) }
    end.compact.sort_by { |x| x[:id] == 'principal' ? 0 : x[:id].to_i }
  end
  def self.copia(x) JSON.parse(JSON.generate(x), symbolize_names: true) end
  # numeração única no projeto: cada plano começa depois do maior número dos planos anteriores
  def self.maior_numero(o)
    return o['numMax'].to_i if o['numMax']
    foto = (JSON.parse(o['foto'].to_s) rescue [])
    n_foto = foto.sum { |f| (f['pos'] || []).size }
    n_proj = (o.dig('conf', 'proj', 'pecas') || {}).size
    n_pec = (o['pecas'] || []).size
    o['numBase'].to_i + n_foto
  end
  def self.ordem_plano(id) id == 'principal' ? 1 : id.to_i end
  def self.base_numeros(id)
    ordem = ordem_plano(id)
    listar_planos.map { |x| x[:id] }.select { |i| ordem_plano(i) < ordem }.map { |i| o = ler_plano(i); o ? maior_numero(o) : 0 }.max.to_i
  end
  # nº das chapas também não repete: o plano começa depois das chapas dos planos anteriores
  def self.base_chapas(id)
    ordem = ordem_plano(id)
    listar_planos.map { |x| x[:id] }.select { |i| ordem_plano(i) < ordem }.sum { |i| o = ler_plano(i); o ? (o['n'] || ((JSON.parse(o['foto'].to_s) rescue []).size)).to_i : 0 }
  rescue
    0
  end
  # abre a tela com estes dados
  # cliente / OS / ambiente tirados da pasta do projeto: "...\\- 18. Fabrício e Aline\\26.146 - ESCADA\\Projeto Tecnico\\x.skp"
  def self.info_pasta(caminho)
    partes = caminho.to_s.tr('\\', '/').split('/')
    i = partes.rindex { |x| x =~ /^\s*\d{2}\.\d{2,3}\s*-\s*\S/ }   # OS 26.84 ou 26.146
    return {} unless i
    os, amb = partes[i].split(/\s*-\s*/, 2).map(&:strip)
    cli = i > 0 ? partes[i - 1].sub(/^[\s\-]*\d+\s*[.\-]\s*/, '').strip : ''
    { cliente: cli, os: os, amb: amb.to_s }
  rescue
    {}
  end
  def self.mostrar(dados)
    dados[:pastaInfo] ||= info_pasta(caminho_projeto)
    dados[:externo] = true if @projeto_externo
    dados[:projetoChave] = dados[:extChave] || (nome_plano rescue nil)
    @externo = dados[:externo].is_a?(Hash) ? dados[:externo] : nil   # plano aberto da lista da nuvem (Hash); true = aberto pelo Início
    dados[:cfgComum] = (JSON.parse(File.read(File.join(pasta_comum, 'config.json'), encoding: 'UTF-8')) rescue nil)
    (checar_atualizacao(true) rescue nil)   # se tiver versão nova, instala sozinho
    (checar_online rescue nil)              # e pela internet, na hora
    (espalhar_versao rescue nil)            # se este PC tiver a mais nova, põe no Dropbox para os outros
    @dados_atual = dados; @plano_id = id_plano(dados[:planoId]); @plano_nome = dados[:planoNome]
    @dados_json = JSON.generate(dados).gsub('</', '<\/')
    html = File.read(MODELO_TELA, encoding: 'UTF-8').sub('__DADOS__') { @dados_json }
    @mt_tela = File.mtime(MODELO_TELA) rescue nil
    nome_arq = dados[:projeto].to_s.gsub(/[\\\/:*?"<>|]/, '_').unicode_normalize(:nfkd).gsub(/[^\x00-\x7F]/, '')
    saida = File.join(ENV['TEMP'] || Dir.tmpdir, "PCF SketchUp - #{nome_arq}.html")
    File.write(saida, html, mode: 'w:UTF-8')
    @saida = saida
    abrir_tela(saida)
    iniciar_vigia
  end
  # junta a configuração que chega da tela com a do Dropbox: veio / dupla face / lâmina marcados à mão
  # (marcT) nunca são perdidos por um PC que estava com a tela aberta desde antes (vale a marcação mais nova)
  def self.juntar_cfg(arq, txt)
    novo = JSON.parse(txt) rescue (return txt)
    velho = (JSON.parse(File.read(arq, encoding: 'UTF-8')) rescue nil)
    return txt unless velho.is_a?(Hash) && novo.is_a?(Hash)
    tv = velho['marcT'] || {}; tn = novo['marcT'] || {}
    t = tv.merge(tn) { |_, a, b| [a.to_i, b.to_i].max }
    %w[veio dupla lamina].each do |k|
      novo[k] ||= {}
      (velho[k] || {}).each do |cor, v|
        chave = "#{k}|#{cor}"
        a = tv[chave].to_i; b = tn[chave].to_i
        if a > b then novo[k][cor] = v
        elsif a == 0 && b == 0 && !novo[k].key?(cor) then novo[k][cor] = v
        elsif a == 0 && b == 0 && v == true then novo[k][cor] = true
        end
      end
    end
    novo['marcT'] = t
    JSON.generate(novo)
  rescue
    txt
  end
  # reiniciar do zero: TODOS os planos deste projeto vão para o histórico e começa um plano novo com o que está visível agora
  def self.zerar_planos
    require 'fileutils'
    pd = pasta_planos; h = File.join(pd, 'historico'); FileUtils.mkdir_p(h)
    carimbo = Time.now.strftime('%Y-%m-%d %H-%M-%S')
    re = /\A#{Regexp.escape(nome_plano)}(\.[\w\-]+)?\.json\z/
    arqs = Dir.children(pd).select { |n| n =~ re }.map { |n| File.join(pd, n) }
    pth = caminho_projeto
    unless pth.empty?
      base = File.basename(pth, '.*') + '.pcfplano'
      re2 = /\A#{Regexp.escape(base)}(\.[\w\-]+)?\.json\z/
      arqs += Dir.children(File.dirname(pth)).select { |n| n =~ re2 }.map { |n| File.join(File.dirname(pth), n) }
    end
    (listar_planos.each { |x| nuvem_enfileirar(nome_plano, x[:id], nil, nil, nil, { 'excluido' => true }) } rescue nil)
    arqs.each_with_index do |f, i|
      FileUtils.mv(f, File.join(h, nome_plano + ' ' + carimbo + " (reiniciado do zero #{i + 1})" + '.json')) rescue (File.delete(f) rescue nil)
    end
    @excluidos = []; @plano_id = 'principal'
    enviar(true)
  rescue => e
    UI.messagebox("Não consegui reiniciar: #{e.message}") rescue nil
  end
  # ==== ☁ 📋 CLIENTES e OSs NA NUVEM, dentro da CONTA do login (PCF Ferramentas · Firebase os-moveis) ====
  # cada plano salvo vai para pcf_planos/<conta>/itens/<código>; sem login (ou sem internet) fica numa fila no PC
  # (%APPDATA%\PCF Label\nuvem_fila) e sobe sozinho quando a conta estiver entrada. Nada vai para o Dropbox.
  def self.conta_pcf
    f = defined?(PCF::Ferramentas) ? PCF::Ferramentas : nil
    (f && f.respond_to?(:fs_gravar) && f.respond_to?(:liberado?) && f.respond_to?(:com_token)) ? f : nil
  end
  def self.conta_info
    f = conta_pcf; return nil unless f && f.liberado?
    c = f.instance_variable_get(:@conta) || {}
    c[:uid] ? c : nil
  end
  # nº do plano na conta. Com o caminho do projeto: o MESMO nº em todos os PCs (conta a partir da pasta do Dropbox),
  # assim o plano salvo num PC é o mesmo nos outros (antes cada PC criava o seu e o plano aparecia repetido)
  def self.doc_plano(chave, id, skp = nil)
    require 'digest/md5'
    base = skp.to_s.empty? ? chave.to_s : 'rel:' + chave_rel(skp)
    Digest::MD5.hexdigest(base + sufixo_plano(id))[0, 20]
  end
  def self.pasta_fila
    d = File.join(ENV['APPDATA'] || Dir.tmpdir, 'PCF Label', 'nuvem_fila'); FileUtils.mkdir_p(d) rescue nil; d
  end
  # põe o plano (ou só uma marca, ex.: excluído) na fila para subir para a conta
  def self.nuvem_enfileirar(chave, id, obj, txt, skp, extra = nil)
    require 'fileutils'; require 'zlib'; require 'base64'
    k = doc_plano(chave, id, skp)
    item = { 'doc' => k }
    # o nº antigo deste PC (de antes): marca como excluído uma vez, para não ficar repetido na lista
    velho = doc_plano(chave, id)
    if velho != k && !(@migrados ||= {})[velho]
      @migrados[velho] = true
      File.binwrite(File.join(pasta_fila, velho + '.marca.json'), JSON.generate('doc' => velho, 'campos' => { 'excluido' => true }, 'mascara' => ['excluido']).b) rescue nil
    end
    if obj
      pr = (obj.dig('conf', 'proj') || {}); pi = skp.to_s.empty? ? {} : info_pasta(skp)
      cli = pr['cliente'].to_s.strip; cli = pi[:cliente].to_s if cli.empty?
      os = pr['os'].to_s.strip; os = pi[:os].to_s if os.empty?
      amb = pr['amb'].to_s.strip; amb = pi[:amb].to_s if amb.empty?
      item['campos'] = { 'chave' => chave.to_s, 'id' => id_plano(id), 'nome' => obj['nome'].to_s, 'cliente' => cli, 'os' => os, 'amb' => amb,
                         'projeto' => obj['projeto'].to_s, 'skp' => skp.to_s, 'data' => obj['data'].to_s, 'criado' => obj['criado'].to_s, 'gerado' => (!obj['gc'].nil? && obj['gc'] != false), 'salvo' => !obj['salvo'].to_s.empty?, 't' => obj['t'].to_i, 'n' => obj['n'].to_i,
                         'pecas' => (obj['pecas'] || []).count { |p| !p['dentro'] }, 'pc' => ENV['COMPUTERNAME'].to_s, 'excluido' => false,
                         'dados' => Base64.strict_encode64(Zlib::Deflate.deflate(txt.to_s.b, 9)) }
    end
    if extra
      item['campos'] = (item['campos'] || {}).merge(extra)
      item['mascara'] = extra.keys unless obj
    end
    File.binwrite(File.join(pasta_fila, k + (obj ? '' : '.marca') + '.json'), JSON.generate(item).b)
    UI.start_timer(3, false) { nuvem_subir rescue nil } unless @subir_marcado; @subir_marcado = true
  rescue
    nil
  end
  # sobe a fila (um de cada vez); o que der certo sai da fila
  def self.nuvem_subir
    @subir_marcado = false
    f = conta_pcf; c = conta_info
    return unless f && c && !@subindo
    nuvem_semear(c[:uid])
    fila = Dir.glob(File.join(pasta_fila, '*.json').tr('\\', '/')).sort_by { |x| File.mtime(x) }
    return if fila.empty?
    @subindo = true
    um = lambda do |i|
      if i >= fila.size then @subindo = false; next end
      arq = fila[i]; it = (JSON.parse(File.read(arq, encoding: 'UTF-8')) rescue nil)
      unless it && it['doc'] && it['campos'] then (File.delete(arq) rescue nil); next um.call(i + 1) end
      f.fs_gravar("pcf_planos/#{c[:uid]}/itens/#{it['doc']}", it['campos'], it['mascara']) do |s, _d|
        (File.delete(arq) rescue nil) if s == 200
        @nuvem_erro = s == 200 ? nil : s
        um.call(i + 1)
      end
    end
    um.call(0)
  rescue
    @subindo = false
  end
  # 1ª vez nesta conta neste PC: os planos que já existem no PC entram na lista da nuvem
  def self.nuvem_semear(uid)
    chv = "nuvem_semeado_#{uid}"
    return if Sketchup.read_default('PCFLabel', chv, false)
    Sketchup.write_default('PCFLabel', chv, true)
    Dir.glob(File.join(pasta_planos, '*.json').tr('\\', '/')).each do |arq|
      txt = File.binread(arq).force_encoding('UTF-8'); o = (JSON.parse(txt) rescue nil); next unless o.is_a?(Hash) && o['foto']
      id = id_plano(o['id']); b = File.basename(arq, '.json')
      chave = id == 'principal' ? b : b.sub(/\.#{Regexp.escape(id)}\z/, '')
      nuvem_enfileirar(chave, id, o, txt, '')
    end
  rescue
    nil
  end
  def self.responder_clientes(h)
    if (@dlg.nil? || !@dlg.visible?) && h[:ok] == false then (@dlg.close rescue nil); UI.messagebox("PCF Label: #{h[:msg]}"); return end
    @dlg.execute_script("mostrarClientes(#{JSON.generate(h).gsub('</', '<\\/')})") rescue nil
  end
  # lista de clientes / OSs / planos da conta (só os dados de cima, sem baixar os planos)
  def self.nuvem_listar
    f = conta_pcf
    return responder_clientes(ok: false, semConta: true, msg: 'O login (conta) ainda não está instalado neste PC. Atualize o PCF Ferramentas (⬆).') unless f
    c = conta_info
    return responder_clientes(ok: false, login: true, msg: 'Entre na sua conta para ver os clientes e as OSs.') unless c
    nuvem_subir
    campos = %w[chave id nome cliente os amb projeto skp data criado gerado salvo t n pecas pc excluido]
    url0 = "#{PCF::Ferramentas::FS_URL rescue 'https://firestore.googleapis.com/v1/projects/os-moveis/databases/(default)/documents/'}pcf_planos/#{c[:uid]}/itens?pageSize=300&" + campos.map { |x| "mask.fieldPaths=#{x}" }.join('&')
    tudo = []
    pagina = lambda do |tok|
      f.com_token do |ok|
        next responder_clientes(ok: false, msg: 'Sem internet ou a conta saiu. Tente de novo.') unless ok
        cc = f.instance_variable_get(:@conta)
        f.http(Sketchup::Http::GET, url0 + (tok ? "&pageToken=#{tok}" : ''), nil, cc[:id]) do |s, d|
          next responder_clientes(ok: false, msg: "A nuvem não respondeu (#{s}). Tente de novo.") unless s == 200
          tudo += (d['documents'] || []).map { |x| f.fs_doc(x).merge('k' => x['name'].to_s.split('/').last) }
          next pagina.call(d['nextPageToken']) if d['nextPageToken']
          atual = (nome_plano rescue nil)
          fila = Dir.glob(File.join(pasta_fila, '*.json')).size
          lista = tudo.reject { |m| m['excluido'] }.map { |m| m.merge('temSkp' => (!m['skp'].to_s.empty? && File.exist?(m['skp'].to_s)), 'atual' => m['chave'] == atual) }
          responder_clientes(ok: true, lista: lista.sort_by { |m| -m['t'].to_i }, email: cc[:email].to_s, fila: fila)
        end
      end
    end
    pagina.call(nil)
  rescue => e
    responder_clientes(ok: false, msg: "Erro: #{e.message}")
  end
  # 🗑 exclui um plano da lista de clientes — só com a SENHA da conta PCF (conferida no login da conta, não fica guardada)
  # na nuvem fica marcado como excluído; os arquivos do plano neste PC vão para o histórico (dá para recuperar)
  # ---------- EXCLUIR: 📝 rascunho (sem G-code) sem senha · ✔ gerado (G-code já feito) só com a SENHA da conta PCF ----------
  def self.gerado_obj?(o) o.is_a?(Hash) && !o['gc'].nil? && o['gc'] != false && o['gc'] != 0 end
  def self.gerado_arq?(arq) gerado_obj?((JSON.parse(File.read(arq, encoding: 'UTF-8')) rescue nil)) end
  # confere a senha só quando precisa (plano gerado); a senha vai só para o login da conta e não fica guardada
  def self.conferir_senha(precisa, senha, &fim)
    return fim.call(true, nil) unless precisa
    f = conta_pcf; c = conta_info
    return fim.call(false, 'Plano gerado: entre na sua conta (👤 Conta) para excluir com a senha.') unless f && c
    return fim.call(false, 'Plano gerado (G-code já feito): digite a senha da conta para excluir.') if senha.to_s.empty?
    sc = f.singleton_class
    f.http(Sketchup::Http::POST, "#{sc.const_get(:AUTH_URL)}signInWithPassword?key=#{sc.const_get(:FB_CHAVE)}", { 'email' => c[:email].to_s, 'password' => senha.to_s, 'returnSecureToken' => false }) do |s, _r|
      s == 200 ? fim.call(true, nil) : fim.call(false, s == 0 ? 'Sem internet: não deu para conferir a senha.' : 'Senha errada. Não foi excluído.')
    end
  rescue => e
    fim.call(false, "Erro: #{e.message}")
  end
  # o plano está gerado? (arquivo deste PC; se ele só existe na conta, pergunta à conta; sem como saber = trata como gerado)
  def self.gerado_plano(skp, id, k, chave = nil, &fim)
    suf = sufixo_plano(id); arqs = []
    unless skp.to_s.empty?
      arqs << File.join(File.dirname(skp), File.basename(skp, '.*') + '.pcfplano' + suf + '.json')
      arqs << File.join(pasta_planos, chave_de_skp(skp) + suf + '.json')
    end
    arqs << File.join(pasta_planos, chave.to_s + suf + '.json') unless chave.to_s.empty?
    a = arqs.select { |x| File.exist?(x) }.max_by { |x| File.mtime(x) }
    return fim.call(gerado_arq?(a)) if a
    f = conta_pcf; c = conta_info
    return fim.call(true) unless f && c && !k.to_s.empty?
    f.fs_get("pcf_planos/#{c[:uid]}/itens/#{k}") { |s, m| fim.call(s == 200 && m ? !!m['gerado'] : true) }
  rescue
    fim.call(true)
  end
  # marca como excluído na conta (quando tem conta e o plano está lá)
  def self.marcar_excluido_nuvem(doc, &fim)
    f = conta_pcf; c = conta_info
    docs = Array(doc).compact.uniq
    return fim.call(true, nil) unless f && c && !docs.empty?
    um = lambda do |i|
      next fim.call(true, nil) if i >= docs.size
      f.fs_gravar("pcf_planos/#{c[:uid]}/itens/#{docs[i]}", { 'excluido' => true, 'excluido_em' => Time.now.strftime('%d/%m/%Y %H:%M') }, %w[excluido excluido_em]) do |s2, _d2|
        s2 == 200 ? um.call(i + 1) : fim.call(false, "A nuvem não respondeu (#{s2}). Tente de novo.")
      end
    end
    um.call(0)
  end
  # 🗑 lista de Clientes e OSs
  def self.nuvem_excluir(h)
    k = h['k'].to_s; id = id_plano(h['id']); skp = h['skp'].to_s.empty? ? '' : caminho_local(h['skp'])
    gerado_plano(skp, id, k, h['chave']) do |ger|
      conferir_senha(ger, h['senha']) do |ok, msg|
        next responder_exclusao(false, msg, ger) unless ok
        marcar_excluido_nuvem(k.empty? ? nil : k) do |ok2, msg2|
          next responder_exclusao(false, msg2) unless ok2
          (arquivar_plano_lista(h) rescue nil)
          responder_exclusao(true, 'Plano excluído.')
          UI.start_timer(0.3, false) { nuvem_listar }
        end
      end
    end
  rescue => e
    responder_exclusao(false, "Erro: #{e.message}")
  end
  def self.responder_exclusao(ok, msg, senha = false)
    @dlg.execute_script("exclusaoResposta(#{JSON.generate(ok: ok, msg: msg, senha: senha)})") rescue nil
  end
  # 🕘 versões salvas: apaga uma cópia do histórico (a de plano gerado pede a senha)
  def self.hist_excluir(h)
    arq = File.join(pasta_planos, 'historico', File.basename(h['arq'].to_s))
    js = ->(o) { @dlg.execute_script("versaoExcluida(#{JSON.generate(o)})") rescue nil }
    return js.(ok: false, arq: h['arq'], msg: 'Essa versão não existe mais.') unless File.exist?(arq)
    ger = gerado_arq?(arq)
    conferir_senha(ger, h['senha']) do |ok, msg|
      next js.(ok: false, arq: h['arq'], msg: msg, senha: ger) unless ok
      File.delete(arq) rescue (next js.(ok: false, arq: h['arq'], msg: 'Não consegui apagar o arquivo.'))
      js.(ok: true, arq: h['arq'])
    end
  end
  # 🗑 Planos deste projeto (dentro da janela): rascunho sem senha, gerado com senha
  def self.plano_excluir_conf(h)
    id = id_plano(h['id']); ger = gerado_obj?(ler_plano(id))
    js = ->(o) { @dlg.execute_script("planoExcluidoResp(#{JSON.generate(o)})") rescue nil }
    conferir_senha(ger, h['senha']) do |ok, msg|
      next js.(ok: false, id: id, msg: msg, senha: ger) unless ok
      js.(ok: true, id: id)
      UI.start_timer(0.1, false) { excluir_plano(id) }
    end
  end
  # tira o plano deste PC (vai para o histórico): o da pasta de planos e o que fica junto do projeto .skp
  def self.arquivar_plano_lista(h)
    require 'fileutils'
    chave = h['chave'].to_s; id = id_plano(h['id']); suf = sufixo_plano(id); skp = h['skp'].to_s
    return if chave.empty?
    if chave == (nome_plano rescue nil) && @dlg && @dlg.visible? && @dados_vivos
      excluir_plano(id) # é do projeto aberto: usa a exclusão normal (a tela se ajusta)
      return
    end
    pd = pasta_planos; hist = File.join(pd, 'historico'); FileUtils.mkdir_p(hist)
    carimbo = Time.now.strftime('%Y-%m-%d %H-%M-%S')
    arqs = [File.join(pd, chave + suf + '.json')]
    arqs << File.join(File.dirname(skp), File.basename(skp, '.*') + '.pcfplano' + suf + '.json') unless skp.empty?
    arqs.each_with_index do |a, i|
      next unless File.exist?(a)
      FileUtils.mv(a, File.join(hist, chave + suf + ' ' + carimbo + (i > 0 ? " (excluído, cópia #{i})" : ' (excluído)') + '.json')) rescue nil
    end
  end
  # abre um plano da lista (de QUALQUER projeto, mesmo com outro projeto aberto)
  def self.nuvem_abrir(k)
    f = conta_pcf; c = conta_info
    return responder_clientes(ok: false, login: true, msg: 'Entre na sua conta para abrir.') unless f && c
    f.fs_get("pcf_planos/#{c[:uid]}/itens/#{k}") do |s, m|
      begin
        next responder_clientes(ok: false, msg: "Não consegui baixar esse plano (#{s}).") unless s == 200 && m && m['dados']
        require 'zlib'; require 'base64'
        txt = Zlib::Inflate.inflate(Base64.decode64(m['dados'])).force_encoding('UTF-8')
        pl = JSON.parse(txt); id = id_plano(m['id'])
        if m['chave'].to_s == (nome_plano rescue nil) && @dados_vivos
          # é do projeto aberto agora: se a da nuvem for mais nova, ela vale; abre normal (com as peças vivas do SketchUp)
          loc = ler_plano(id)
          if loc.nil? || pl['t'].to_i > loc['t'].to_i
            (File.binwrite(File.join(pasta_planos, nome_plano + sufixo_plano(id) + '.json'), txt.b) rescue nil)
            a = arq_plano_modelo(id); (File.binwrite(a, txt.b) rescue nil) if a
          end
          next abrir_plano(id)
        end
        abrir_externo(m, pl)
      rescue => e
        responder_clientes(ok: false, msg: "Não consegui abrir: #{e.message}")
      end
    end
  end
  def self.abrir_externo(m, pl)
    id = id_plano(m['id']); chave = m['chave'].to_s; skp = m['skp'].to_s
    d = @dados_vivos ? copia(@dados_vivos) : { materiais: [], espessura: 18.3, chapa: '1850 x 2750', selecao: false, origem: 'sketchup', bancoCores: banco_arquivo.to_s }
    d[:pecas] = copia(pl['pecas'] || []); d[:planoArq] = pl
    d[:projeto] = (pl['projeto'] || m['projeto']).to_s; d[:data] = Time.now.strftime('%d/%m/%Y %H:%M'); d[:compras] = []
    d[:planoId] = id; d[:planoNome] = (pl['nome'] || m['nome']).to_s
    d[:numBase] = pl['numBase'].to_i; d[:chapaBase] = pl['chapaBase'].to_i
    d[:planoEscolhido] = true; d[:planos] = (listar_planos rescue [])
    d[:pastaInfo] = { cliente: m['cliente'].to_s, os: m['os'].to_s, amb: m['amb'].to_s }
    d[:extChave] = chave
    d[:externo] = { chave: chave, id: id, skp: skp, k: m['k'] || doc_plano(chave, id), temSkp: !skp.empty? && File.exist?(skp) }
    mostrar(d)
  end
  # plano aberto da lista (de outro projeto): grava no PC e na conta, nunca no projeto que está aberto
  def self.salvar_plano_externo(txt)
    ex = @externo; obj = (JSON.parse(txt) rescue nil); return unless obj
    obj['id'] = ex[:id]
    obj['pecas'] ||= JSON.parse(JSON.generate(@dados_atual[:pecas])) if @dados_atual && @dados_atual[:pecas]
    txt = JSON.generate(obj)
    File.binwrite(File.join(pasta_planos, ex[:chave] + sufixo_plano(ex[:id]) + '.json'), txt.b)
    if !ex[:skp].to_s.empty? && File.exist?(ex[:skp].to_s)
      a = File.join(File.dirname(ex[:skp]), File.basename(ex[:skp], '.*') + '.pcfplano' + sufixo_plano(ex[:id]) + '.json')
      (File.binwrite(a, txt.b) rescue nil)
    end
    nuvem_enfileirar(ex[:chave], ex[:id], obj, txt, ex[:skp])
  end
  def self.abrir_projeto_lista(k, skp)
    return UI.messagebox("Não achei o projeto neste PC:\n#{skp}") unless File.exist?(skp.to_s)
    @abrir_depois = true
    Sketchup.open_file(skp)
    UI.start_timer(1.5, false) { enviar if @abrir_depois; @abrir_depois = false }
  end
  # exclui um plano: os arquivos vão para o histórico (dá para recuperar em "Versões"), não some de vez
  def self.excluir_plano(id)
    require 'fileutils'
    id = id_plano(id); suf = sufixo_plano(id); pd = pasta_planos; h = File.join(pd, 'historico'); FileUtils.mkdir_p(h)
    (@excluidos ||= []) << nome_plano + suf
    (nuvem_enfileirar(nome_plano, id, nil, nil, caminho_projeto, { 'excluido' => true }) rescue nil)
    carimbo = Time.now.strftime('%Y-%m-%d %H-%M-%S')
    [File.join(pd, nome_plano + suf + '.json'), arq_plano_modelo(id)].compact.each_with_index do |f, i|
      next unless File.exist?(f)
      FileUtils.mv(f, File.join(h, nome_plano + suf + ' ' + carimbo + (i > 0 ? " (excluído, cópia #{i})" : ' (excluído)') + '.json')) rescue (File.delete(f) rescue nil)
    end
    if id == @plano_id
      @dados_vivos ? (planos = listar_planos; planos.empty? ? enviar(true) : abrir_plano(planos.max_by { |x| x[:t].to_i }[:id])) : enviar(true)
    else
      @dlg.execute_script("planosAtualizados(#{JSON.generate(listar_planos).gsub('</', '<\\/')})") rescue nil
    end
  rescue => e
    UI.messagebox("Não consegui excluir o plano: #{e.message}") rescue nil
  end
  # itens de compra (trilhos, kits, perfis, vidros) gravados pelo PCF Ferramentas (botão Correr): somados por código
  def self.lista_compras
    m = Sketchup.active_model
    tot = {}
    m.entities.each do |e|
      next unless e.respond_to?(:get_attribute) && e.get_attribute('pcf', 'correr_modulo') && e.visible?
      (JSON.parse(e.get_attribute('pcf', 'compra').to_s) rescue []).each do |c|
        k = [c['cod'], c['desc'], c['un']].join('|')
        tot[k] ||= { cod: c['cod'].to_s, desc: c['desc'].to_s, un: c['un'].to_s, qtd: 0.0, modulos: [] }
        tot[k][:qtd] += c['qtd'].to_f
        nm = e.name.to_s.split(' - ').last.to_s
        tot[k][:modulos] << nm unless nm.empty? || tot[k][:modulos].include?(nm)
      end
    end
    tot.values.map { |c| c.merge(qtd: c[:qtd].round(2)) }
  end

  def self.abrir_plano(id)
    return unless @dados_vivos
    id = id_plano(id)
    (@excluidos ||= []).delete(nome_plano + sufixo_plano(id))
    d = copia(@dados_vivos)
    pl = ler_plano(id)
    if pl
      if pl['pecas'].is_a?(Array) && !pl['pecas'].empty?
        # o plano guarda as peças de quando foi feito; peça que apareceu depois no projeto (estava oculta, foi desenhada…)
        # entra junto, para cair em "fora do plano" e ganhar lugar sem mexer nas chapas que você já ajustou
        # peça que está no projeto vem com a medida de AGORA (você mexeu nela → o plano ajusta);
        # peça do plano que só está oculta continua igual; peça apagada do projeto sai do plano
        base = ->(x) { (x['id'] || x[:id]).to_s.sub(/\Ask/, '').split('#').first.to_s }
        vivas = copia(@dados_vivos[:pecas] || [])
        ids_vivos = vivas.map { |x| base.call(x) }
        mod = Sketchup.active_model
        # peças do plano que não estão entre as vivas: procura todas de uma vez (uma a uma = ~0,3 s cada em projeto grande)
        vivos_h = {}
        ids_vivos.each { |b| vivos_h[b] = true }
        procurar = copia(pl['pecas']).map { |x| base.call(x) }.reject { |b| vivos_h[b] || b !~ /\A\d+\z/ }.uniq
        existe = {}
        unless procurar.empty?
          ach = (mod.find_entity_by_persistent_id(*procurar.map(&:to_i)) rescue nil)
          ach = [ach] unless ach.is_a?(Array)
          procurar.each_with_index { |b, i| existe[b] = !ach[i].nil? }
        end
        ocultas = copia(pl['pecas']).reject { |x| b = base.call(x); vivos_h[b] || (b =~ /\A\d+\z/ && !existe[b]) }
        d[:pecas] = vivas + ocultas
      end
      d[:planoArq] = pl
    else
      d[:planoArq] = nil
    end
    d[:planoId] = id; d[:planoNome] = (pl && pl['nome']) || (id == 'principal' ? 'Plano principal' : "Plano #{id}")
    d[:numBase] = (pl && pl['numBase']) ? pl['numBase'].to_i : (id == 'principal' ? 0 : base_numeros(id))
    d[:chapaBase] = base_chapas(id)
    d[:planoEscolhido] = true; d[:planos] = listar_planos
    mostrar(d)
  end
  def self.novo_plano
    return unless @dados_vivos
    usados = listar_planos.map { |x| x[:id].to_i }
    n = 2; n += 1 while usados.include?(n)
    d = copia(@dados_vivos)
    base = ler_plano(@plano_id || 'principal') || ler_plano('principal')
    d[:planoArq] = nil; d[:confHerdada] = base && base['conf']
    (@excluidos ||= []).delete(nome_plano + sufixo_plano(n.to_s))
    d[:planoId] = n.to_s; d[:planoNome] = "Plano #{n}"; d[:numBase] = base_numeros(n.to_s); d[:chapaBase] = base_chapas(n.to_s); d[:planoEscolhido] = true; d[:planos] = listar_planos
    mostrar(d)
  end

  # botão PCF (ponte com o Aspire): se não estiver rodando, abre
  BOTAO_VBS = 'C:\\Users\\Public\\Documents\\Vectric Files\\Gadgets\\Aspire V12.0\\PCF Label\\botao.vbs'
  def self.garantir_botao
    return unless File.exist?(BOTAO_VBS)   # sem o botão do Aspire neste PC: nem consulta o Windows (~60–130 ms)
    require 'win32ole'
    procs = (WIN32OLE.connect('winmgmts://').ExecQuery("select CommandLine from Win32_Process where Name='powershell.exe'").each.map { |p| p.CommandLine.to_s } rescue nil)
    return if procs.nil? || procs.any? { |c| c =~ /botao\.ps1/i }
    WIN32OLE.new('WScript.Shell').Run('wscript.exe "' + BOTAO_VBS + '"', 0, false) if File.exist?(BOTAO_VBS)
  rescue
    nil
  end

  def self.vigiar
    @n_vigia = (@n_vigia || 0) + 1
    PCFLabel.garantir_botao if @n_vigia % 75 == 1 # confere o botão do Aspire a cada ~5 min (a consulta ao Windows travava o SketchUp ~0,1 s a cada 32 s)
    mp = (File.mtime(ARQ_PLUGIN) rescue nil)
    if mp && @mt_plugin && mp != @mt_plugin
      @mt_plugin = mp
      load ARQ_PLUGIN
      (PCFLabel.callbacks(@dlg) rescue nil) if @dlg
    end
    return unless @dlg && @dlg.visible? && @dados_json && @saida
    mt = (File.mtime(MODELO_TELA) rescue nil)
    return unless mt && @mt_tela && mt != @mt_tela
    @mt_tela = mt
    # NUNCA recarrega sozinha com você trabalhando (fazia perder o que estava fazendo): só avisa;
    # a tela nova entra quando você clicar no aviso ou abrir a janela de novo
    (@dlg.execute_script("try{avisoTelaNova()}catch(e){}") rescue nil)
  end
  # 📂 Abrir último plano: lê de novo o plano mais novo (arquivo ao lado do projeto / deste PC / conta) e reabre a janela
  # com ELE (sem gravar antes o que estava na tela, que pode ser o velho)
  def self.abrir_ultimo_plano
    return unless @dlg && @dados_json && @saida
    if @externo.is_a?(Hash) && @externo[:k]
      k = @externo[:k]; (@dlg.close rescue nil); return nuvem_abrir(k)
    end
    pl = ler_plano(@plano_id || 'principal')
    return (@dlg.execute_script("window.SEM_SALVAR=false;$('cncMsg').textContent='Não achei plano salvo deste projeto.'") rescue nil) unless pl
    d = JSON.parse(@dados_json); d['planoArq'] = pl
    @dados_json = JSON.generate(d).gsub('</', '<\\/')
    d['forcarArq'] = true
    File.write(@saida, File.read(MODELO_TELA, encoding: 'UTF-8').sub('__DADOS__') { JSON.generate(d).gsub('</', '<\\/') }, mode: 'w:UTF-8')
    @mt_tela = File.mtime(MODELO_TELA) rescue nil
    @dlg.set_file(@saida)
  rescue => e
    (@dlg.execute_script("window.SEM_SALVAR=false") rescue nil)
    UI.messagebox("PCF Label: não consegui abrir o último plano — #{e.message}") rescue nil
  end
  # recarrega a tela (versão nova) SEM perder o que você fez: primeiro a tela grava o plano de agora,
  # depois abre de novo com o plano mais novo do arquivo (antes abria com o plano de quando a tela foi aberta)
  def self.recarregar_seguro
    return unless @dlg && @dados_json && @saida
    (@dlg.execute_script("try{clearTimeout(salvarPlanoLocal.tm);if(window.PLANO){salvarPlanoLocal()}}catch(e){}") rescue nil)
    UI.start_timer(3.0, false) {
      begin
        d = JSON.parse(@dados_json)
        pl = ler_plano(@plano_id || 'principal')
        d['planoArq'] = pl if pl
        @dados_json = JSON.generate(d).gsub('</', '<\\/')
        File.write(@saida, File.read(MODELO_TELA, encoding: 'UTF-8').sub('__DADOS__') { @dados_json }, mode: 'w:UTF-8')
        @mt_tela = File.mtime(MODELO_TELA) rescue nil
        @dlg.set_file(@saida); log_atu('tela recarregada com o plano mais novo') rescue nil
      rescue => e
        (log_atu("erro ao recarregar: #{e.message}") rescue nil)
      end
    }
  end

  # abre o Aspire e o botão PCF (ponte) se estiverem fechados
  def self.abrir_aspire
    require 'win32ole'
    procs = (WIN32OLE.connect('winmgmts://').ExecQuery("select Name,CommandLine from Win32_Process where Name='Aspire.exe' or Name='powershell.exe'").each.map { |p| [p.Name.to_s, p.CommandLine.to_s] } rescue [])
    tem_asp = procs.any? { |n, _| n =~ /aspire/i }
    tem_bot = procs.any? { |_, c| c =~ /botao\.ps1/i }
    vbs = 'C:\\Users\\Public\\Documents\\Vectric Files\\Gadgets\\Aspire V12.0\\PCF Label\\botao.vbs'
    system('wscript.exe', vbs) unless tem_bot
    lnk = Dir.glob('C:/ProgramData/Microsoft/Windows/Start Menu/Programs/Aspire*/Aspire*.lnk').reject { |x| x =~ /tutorial|manual|website|uninst|data/i }.first
    UI.openURL('file:///' + lnk) if !tem_asp && lnk
    { aspire: tem_asp, botao: tem_bot, abriuAspire: !tem_asp && !lnk.nil?, abriuBotao: !tem_bot }
  end

  # tela fechada: volta a opção de esconder o resto do modelo como estava
  def self.restaurar_vista
    return if @esconder_antes.nil?
    Sketchup.active_model.rendering_options['InactiveHidden'] = @esconder_antes
    @esconder_antes = nil
  end

  # ---- banco de cores compartilhado (na pasta do Dropbox; sem Dropbox, no %APPDATA%) ----
  def self.raiz_dropbox
    p = Sketchup.active_model.path.to_s.tr('\\', '/')
    while (q = File.dirname(p)) != p
      return q if File.basename(q) =~ /dropbox/i
      p = q
    end
    up = (ENV['USERPROFILE'] || '').tr('\\', '/')
    n = (Dir.children(up).find { |x| x =~ /zonta.*dropbox/i } || Dir.children(up).find { |x| x =~ /dropbox/i && File.directory?(File.join(up, x)) }) rescue nil
    n ? File.join(up, n) : nil
  end
  # pasta compartilhada do PCF Label no Dropbox (na raiz do Dropbox de equipe não dá para criar pasta: usa a pasta da empresa)
  def self.pasta_comum
    require 'fileutils'
    raiz = raiz_dropbox
    if raiz
      empresas = (Dir.children(raiz).select { |x| x =~ /zonta|escrit/i && File.directory?(File.join(raiz, x)) } rescue [])
      cands = empresas.map { |x| File.join(raiz, x, 'PCF Label') } + [File.join(raiz, 'PCF Label')]
      ok = cands.find { |c| Dir.exist?(c) }
      return ok if ok
      cands.each { |c| begin; FileUtils.mkdir_p(c); return c; rescue; end }
    end
    File.join(ENV['APPDATA'] || Dir.tmpdir, 'PCF Label')
  end
  def self.banco_arquivo
    File.join(pasta_comum, 'cores.json')
  end

  # ---- atualização automática: arquivos novos na pasta do Dropbox "PCF Label\atualizacao" ----
  PLUGIN_VERSAO = '2026-10-30.12'
  BARRA = 'PCF'   # uma barra só: ferramentas + PCF Label
  # ícone do botão: icones/<nome>.svg (vem pela atualização); sem ele, o .png antigo
  def self.por_icone(cmd, nome, png_antigo)
    (@cmds ||= {})[nome] = cmd
    f = [File.join(__dir__, 'icones', nome + '.svg'), File.join(__dir__, 'icones', nome + '.png'), File.join(__dir__, png_antigo)].find { |x| File.exist?(x) }
    (cmd.small_icon = f; cmd.large_icon = f) if f
  end
  def self.pasta_atualizacao
    File.join(pasta_comum, 'atualizacao')
  end
  # ATUALIZAÇÃO: NÃO atualiza sozinho. Confere a pasta do Dropbox a cada 5 s e, se tiver versão nova,
  # mostra na tela um botão "⬆ Atualização disponível" com o que mudou. Só atualiza quando você clica.
  # ===== ATUALIZAÇÃO PELA INTERNET (sem Dropbox) =====
  # endereço da pasta das versões na internet (ex.: https://raw.githubusercontent.com/<conta>/pcf-label/main/atualizacao/)
  # fica em atualizacao_url.txt na pasta do plugin; sem endereço, não confere pela internet
  URL_ONLINE = 'https://raw.githubusercontent.com/essencialespacopensado-ctrl/pcf-label-atualizacao/main/'
  def self.url_online
    f = File.join(__dir__, 'atualizacao_url.txt')
    u = (File.read(f, encoding: 'UTF-8').strip rescue '')
    u = URL_ONLINE if u.empty?     # endereço oficial das atualizações (o arquivo atualizacao_url.txt, se existir, troca)
    u.end_with?('/') ? u : u + '/'
  end
  def self.baixar(url, &fim)
    return fim.call(nil) unless defined?(Sketchup::Http::Request)
    req = Sketchup::Http::Request.new(url + (url.include?('?') ? '&' : '?') + "t=#{Time.now.to_i}", Sketchup::Http::GET)
    req.start { |_r, res| fim.call(res && res.status_code == 200 ? res.body : nil) rescue nil }
    (@reqs ||= []) << req; @reqs.shift while @reqs.size > 10   # segura a referência até terminar
  rescue
    fim.call(nil) rescue nil
  end
  # pega o nº da última publicação (commit) para baixar a versão exata, sem esperar o cache de 5 min do GitHub
  def self.ultimo_commit(&fim)
    return fim.call(nil) unless defined?(Sketchup::Http::Request)
    k0 = Sketchup.read_default('PCF_Ferramentas', 'nuvem_chave', '').to_s.strip
    # sem chave o GitHub dá só 60 consultas/hora para TODOS os PCs da mesma internet: cada PC pergunta no máx. a cada 15 min
    # e, se o GitHub recusar, espera liberar (o resto do tempo vale o endereço normal, que atualiza em até 5 min)
    agora = Time.now.to_i
    if k0.empty?
      return fim.call(nil) if @api_bloq_ate && agora < @api_bloq_ate
      return fim.call(nil) if @api_ultima && agora - @api_ultima < 900
      @api_ultima = agora
    end
    req = Sketchup::Http::Request.new('https://api.github.com/repos/essencialespacopensado-ctrl/pcf-label-atualizacao/commits/main', Sketchup::Http::GET)
    req.headers = { 'Accept' => 'application/vnd.github.sha', 'User-Agent' => 'PCF-Label' }
    # com a chave da nuvem (☁ Nuvem no Correr) o GitHub deixa conferir toda hora; sem ela, todos os PCs da empresa
    # dividem 60 consultas/hora (mesma internet) e a atualização atrasa
    k = Sketchup.read_default('PCF_Ferramentas', 'nuvem_chave', '').to_s.strip
    req.headers = req.headers.merge('Authorization' => "Bearer #{k}") unless k.empty?
    req.start do |_r, res|
      if res && res.status_code.to_i == 403
        rs = (res.headers['x-ratelimit-reset'] || res.headers['X-RateLimit-Reset']).to_i rescue 0
        @api_bloq_ate = rs > 0 ? rs : Time.now.to_i + 1800
      end
      sha = (res && res.status_code == 200) ? res.body.to_s.strip[/\A[0-9a-f]{40}\z/] : nil
      fim.call(sha) rescue nil
    end
    (@reqs ||= []) << req; @reqs.shift while @reqs.size > 10
  rescue
    fim.call(nil) rescue nil
  end
  def self.checar_online
    u0 = url_online; return unless u0
    return if @online_ocupado; @online_ocupado = true
    ultimo_commit do |sha|
      u = (sha && u0.include?('/main/')) ? u0.sub('/main/', "/#{sha}/") : u0
      checar_online_em(u)
    end
  rescue
    @online_ocupado = false
  end
  def self.checar_online_em(u)
    baixar(u + 'versao.json') do |txt|
      begin
        man = txt && (JSON.parse(txt.dup.force_encoding('UTF-8')) rescue nil)
        (sincronizar_icones(u, man) rescue nil) if man
        (atualizar_ferramentas(u, man) rescue nil) if man
        vt_atual = versao_arq(MODELO_TELA, /VERSAO = '([^']+)'/)
        if man && @pend_label && @pend_label[:chave] == [man['tela'], man['plugin']]
          @online_ocupado = false # já baixada, esperando você clicar em ⬆ Atualizar
        elsif man && (man['tela'].to_s > vt_atual || man['plugin'].to_s > PLUGIN_VERSAO)
          arqs = (man['arquivos'] || ['etiquetas.html', 'main.rb']); baixados = {}
          pega = lambda do |i|
            if i >= arqs.size
              require 'fileutils'; require 'tmpdir'
              tmp = File.join(ENV['TEMP'] || Dir.tmpdir, 'pcf_atualizacao'); FileUtils.mkdir_p(tmp)
              baixados.each { |n, b| File.binwrite(File.join(tmp, n), b) }
              info = { tela: man['tela'], telaAtual: vt_atual, plugin: man['plugin'], pluginAtual: PLUGIN_VERSAO, notas: (man['notas'] || []).first(30) }
              if defined?(PCF::Ferramentas) && PCF::Ferramentas.respond_to?(:marcar_pendente)
                # NÃO instala sozinho: acende o botão ⬆ Atualizar da barra PCF
                @pend_label = { tmp: tmp, info: info, chave: [man['tela'], man['plugin']] }
                PCF::Ferramentas.marcar_pendente
              else
                @pa_online = tmp; aplicar_atualizacao(tmp)
                UI.start_timer(4, false) { (@dlg.execute_script("mostrarAtualizado(#{JSON.generate(info).gsub('</', '<\\/')})") rescue nil) if @dlg }
              end
              @online_ocupado = false
            else
              baixar(u + arqs[i]) { |b| if b && b.bytesize > 50 then baixados[arqs[i]] = b; pega.call(i + 1) else @online_ocupado = false end }
            end
          end
          pega.call(0)
        else
          @online_ocupado = false
        end
      rescue
        @online_ocupado = false
      end
    end
  rescue
    @online_ocupado = false
  end
  # o PCF Label também leva o PCF Ferramentas para a versão do versao.json ("ferramentas"): assim todos os PCs
  # recebem, mesmo os que têm o atualizador antigo do Ferramentas (que o GitHub bloqueava)
  def self.tem_pendente?
    !@pend_label.nil?
  end

  # botão ⬆ Atualizar: instala a versão do PCF Label que já foi baixada e mostra o que mudou
  def self.aplicar_pendente
    pl = @pend_label; return unless pl
    @pend_label = nil
    @pa_online = pl[:tmp]; aplicar_atualizacao(pl[:tmp])
    info = pl[:info]
    UI.start_timer(4, false) { (@dlg.execute_script("mostrarAtualizado(#{JSON.generate(info).gsub('</', '<\\/')})") rescue nil) if @dlg }
    (UI.refresh_toolbars rescue nil)
  end

  def self.atualizar_ferramentas(u, man)
    alvo = man['ferramentas'].to_s
    # Ferramentas novo tem o próprio botão ⬆ Atualizar: aqui só leva os PCs com o atualizador antigo
    return if defined?(PCF::Ferramentas) && PCF::Ferramentas.respond_to?(:marcar_pendente)
    return if alvo.empty? || @ferr_ocupado
    atual = defined?(PCF::Ferramentas::VERSAO) ? PCF::Ferramentas::VERSAO.to_s : '0'
    return unless (alvo.split('.').map(&:to_i) <=> atual.split('.').map(&:to_i)) == 1
    @ferr_ocupado = true
    baixar(u + 'PCF_Ferramentas.rbz') do |b|
      begin
        if b && b.bytesize > 1000
          arq = File.join(ENV['TEMP'] || Dir.tmpdir, "PCF_Ferramentas_#{alvo}.rbz")
          File.binwrite(arq, b)
          Sketchup.install_from_archive(arq, false)
          dir = File.join(Sketchup.find_support_file('Plugins'), 'pcf_ferramentas')
          %w[main criar giro organica paredes pontos curva corte3d interno lista moldura peca_mae correr veio atualizar].each { |n| f = File.join(dir, "#{n}.rb"); load f if File.exist?(f) }
          (PCF::Ferramentas.recarregar_painel rescue nil)
          (log_atu("PCF Ferramentas #{atual} -> #{alvo}") rescue nil)
        end
      rescue => e
        (log_atu("erro ao atualizar PCF Ferramentas: #{e.message}") rescue nil)
      ensure
        @ferr_ocupado = false
      end
    end
  end

  # ícones dos botões também vêm pela internet: versao.json traz "icones" => { "nesting.svg" => sha1 };
  # se o ícone daqui for diferente (ou não existir), baixa da pasta icones/ e troca no botão
  def self.sincronizar_icones(u, man)
    ic = man['icones']; return unless ic.is_a?(Hash) && !ic.empty?
    require 'digest/sha1'; require 'fileutils'
    pasta = File.join(__dir__, 'icones'); FileUtils.mkdir_p(pasta)
    ic.each do |nome, sha|
      next unless nome.to_s =~ /\A[\w\-.]+\.(png|svg)\z/i
      f = File.join(pasta, nome)
      next if (Digest::SHA1.hexdigest(File.binread(f)) rescue '') == sha.to_s
      baixar(u + nome) do |b|
        if b && b.bytesize > 20 && Digest::SHA1.hexdigest(b) == sha.to_s
          (File.binwrite(f, b) rescue nil)
          c = (@cmds || {})[File.basename(nome, '.*')]
          (c.small_icon = f; c.large_icon = f) rescue nil if c
        end
      end
    end
  end
  def self.atualizar_rapido; checar_atualizacao end
  def self.atualizar_sozinho; checar_atualizacao end   # (timers antigos chamam este nome: agora só confere)
  def self.versao_arq(f, rx) (File.read(f, encoding: 'UTF-8')[rx, 1] rescue nil).to_s end
  def self.checar_atualizacao(forcar = false)
    pa = (@pa_rap ||= pasta_atualizacao); return unless pa && Dir.exist?(pa)
    ht = File.join(pa, 'etiquetas.html'); rb = File.join(pa, 'main.rb'); nv = File.join(pa, 'novidades.json')
    sel = [ht, rb, nv, MODELO_TELA].map { |f| (File.mtime(f).to_f rescue 0) }
    return if !forcar && @ult_sel == sel
    @ult_sel = sel
    vt = File.exist?(ht) ? versao_arq(ht, /VERSAO = '([^']+)'/) : ''; vt_atual = versao_arq(MODELO_TELA, /VERSAO = '([^']+)'/)
    vr = File.exist?(rb) ? versao_arq(rb, /PLUGIN_VERSAO = '([^']+)'/) : ''
    if vt > vt_atual || vr > PLUGIN_VERSAO
      notas = ((JSON.parse(File.read(nv, encoding: 'UTF-8')) rescue []) || []).select { |n| n['tela'].to_s > vt_atual || n['plugin'].to_s > PLUGIN_VERSAO }
      @atualizacao = { tela: vt, telaAtual: vt_atual, plugin: vr, pluginAtual: PLUGIN_VERSAO, notas: notas.first(30) }
      # ATUALIZA SOZINHO (pedido do Paulo): instala na hora e depois mostra o que mudou
      info = @atualizacao
      unless @aplicando
        @aplicando = true
        UI.start_timer(1, false) do
          begin
            aplicar_atualizacao
            UI.start_timer(4, false) { (@dlg.execute_script("mostrarAtualizado(#{JSON.generate(info).gsub('</', '<\\/')})") rescue nil) if @dlg }
          ensure
            @aplicando = false
          end
        end
      end
    else
      @atualizacao = nil
    end
  rescue
    nil
  end
  # você clicou em "Atualizar agora": copia do Dropbox e recarrega (o plano fica salvo)
  # registro da atualização na pasta do Dropbox (para o Claude conferir de longe o que aconteceu)
  def self.log_atu(txt)
    f = File.join(pasta_comum, "log_atualizacao_#{(ENV['COMPUTERNAME'] || 'PC')}.txt")
    File.open(f, 'a:UTF-8') { |io| io.puts "#{Time.now.strftime('%d/%m %H:%M:%S')} #{txt}" }
  rescue
    nil
  end
  # este PC tem versão mais nova que a do Dropbox: coloca lá, para os outros PCs pegarem sozinhos
  def self.espalhar_versao
    return   # (15/10) Paulo não quer mais publicar no Dropbox: atualização só pela internet
    require 'fileutils'
    return unless raiz_dropbox
    pa = pasta_atualizacao; FileUtils.mkdir_p(pa)
    ht = File.join(pa, 'etiquetas.html'); rb = File.join(pa, 'main.rb'); fez = []
    if File.exist?(MODELO_TELA) && versao_arq(MODELO_TELA, /VERSAO = '([^']+)'/) > versao_arq(ht, /VERSAO = '([^']+)'/)
      FileUtils.cp(MODELO_TELA, ht); fez << 'tela'
    end
    if PLUGIN_VERSAO > versao_arq(rb, /PLUGIN_VERSAO = '([^']+)'/)
      Dir.glob(File.join(__dir__, '*.{rb,png}')).each { |f| (FileUtils.cp(f, File.join(pa, File.basename(f))) rescue nil) }
      fez << 'plugin'
    end
    nv = File.join(__dir__, 'novidades.json')
    (FileUtils.cp(nv, File.join(pa, 'novidades.json')) rescue nil) if !fez.empty? && File.exist?(nv)
    log_atu("espalhou #{fez.join(' + ')} para o Dropbox (#{pa})") unless fez.empty?
  rescue => e
    (log_atu("ERRO ao espalhar: #{e.message}") rescue nil)
  end
  def self.aplicar_atualizacao(pasta = nil)
    require 'fileutils'
    log_atu("clicou ATUALIZAR · tela local #{versao_arq(MODELO_TELA, /VERSAO = '([^']+)'/)} · plugin #{PLUGIN_VERSAO}")
    pa = pasta || pasta_atualizacao; return unless pa && Dir.exist?(pa)
    ht = File.join(pa, 'etiquetas.html'); rb = File.join(pa, 'main.rb')
    if File.exist?(ht) && versao_arq(ht, /VERSAO = '([^']+)'/) > versao_arq(MODELO_TELA, /VERSAO = '([^']+)'/)
      FileUtils.mkdir_p(File.dirname(MODELO_TELA)); FileUtils.cp(ht, MODELO_TELA)
      (FileUtils.cp(ht, File.join(__dir__, 'etiquetas.html')) rescue nil)
      log_atu("tela copiada: agora #{versao_arq(MODELO_TELA, /VERSAO = '([^']+)'/)}")
      # recarrega a tela aberta já com a versão nova (o plano fica salvo)
      if @dlg && @dados_json && @saida
        @mt_tela = File.mtime(MODELO_TELA) rescue nil
        recarregar_seguro
      end
    else
      log_atu("tela: nada a copiar (Dropbox #{versao_arq(ht, /VERSAO = '([^']+)'/)} existe=#{File.exist?(ht)})")
    end
    if File.exist?(rb) && versao_arq(rb, /PLUGIN_VERSAO = '([^']+)'/) > PLUGIN_VERSAO
      log_atu("plugin #{PLUGIN_VERSAO} -> #{versao_arq(rb, /PLUGIN_VERSAO = '([^']+)'/)}")
      Dir.glob(File.join(pa, '*.png')).each { |p| (FileUtils.cp(p, File.join(__dir__, File.basename(p))) rescue nil) }
      Dir.glob(File.join(pa, '*.rb')).reject { |p| File.basename(p) == 'main.rb' }.each { |p| (FileUtils.cp(p, File.join(__dir__, File.basename(p))) rescue nil) }
      FileUtils.cp(rb, File.join(__dir__, 'main.rb'))
      load File.join(__dir__, 'main.rb')
      (callbacks(@dlg) rescue nil) if @dlg
    end
    @atualizacao = nil; @ult_sel = nil
  rescue => e
    log_atu("ERRO: #{e.class} #{e.message}")
    UI.messagebox("Não consegui atualizar: #{e.message}") rescue nil
  end
  def self.banco_cores
    f = banco_arquivo
    File.exist?(f) ? (JSON.parse(File.read(f, encoding: 'UTF-8')) rescue {}) : {}
  end
  def self.salvar_banco(banco, mats)
    novo = banco.dup
    mats.each { |cod, m| next if cod.to_s.empty?; n = (m[:nome].to_s.strip.empty? ? m[:sugestao] : m[:nome]).to_s.strip
      novo[cod] ||= { 'nome' => n, 'fonte' => 'automatico', 'textura' => m[:textura].to_s } unless n.empty?
      if novo[cod].is_a?(Hash) && ![true, false].include?(novo[cod]['veio']) && [true, false].include?(m[:veio]) then novo[cod] = novo[cod].merge('veio' => m[:veio], 'veio_fonte' => 'automatico') end }
    return if novo == banco
    require 'fileutils'; f = banco_arquivo; FileUtils.mkdir_p(File.dirname(f))
    File.binwrite(f, JSON.pretty_generate(novo).b)
  rescue
    nil
  end
  # nome da cor: 1) o que já está no banco  2) o nome que o Dinabox dá  3) o nome da textura
  # mesma cor em variações (101969_H / 101969_V / 65965_H1 / white1): cadastrou uma, vale para todas
  def self.base_cor(cod)
    c = cod.to_s.strip
    return c.downcase if c =~ /^DB\d+$/i
    c.sub(/[_\s-]+[HV]\d*$/i, '').sub(/(?<=[A-Za-z])\d{1,2}$/, '').strip.downcase
  end
  # cadastro de verdade (você ou o Dinabox deu o nome) desta cor ou de uma variação dela
  def self.reg_cor(cod, banco)
    ok = ->(b) { b.is_a?(Hash) && !b['nome'].to_s.strip.empty? && b['fonte'] != 'automatico' }
    return banco[cod] if ok.(banco[cod])
    bc = base_cor(cod); return nil if bc.empty?
    banco.each { |k, v| return v if k != cod && ok.(v) && base_cor(k) == bc }
    nil
  end
  # nome certo (sem chute): cadastro seu/variação, ou o nome que o próprio Dinabox dá à cor
  def self.nome_conhecido(cod, mt, banco)
    r = reg_cor(cod, banco); return r['nome'].to_s.strip if r
    # materiais próprios do Dinabox (DB inox, db_preto, db_metal8…): o nome está no próprio material
    if cod.to_s =~ /^db[\s_]+([a-zà-ú].*)$/i
      t = $1.tr('_', ' ').sub(/\d+$/, '').strip; return t[0].upcase + t[1..-1] unless t.empty?
    end
    if cod.to_s =~ /^DB\d+$/i
      tx = File.join(Sketchup.find_support_file('Plugins'), 'DinaBox', 'materiais', "#{cod}.txt")
      n = (File.binread(tx).force_encoding('UTF-8')[/\[NOME\](.*?)\[\/NOME\]/m, 1].to_s.strip rescue '')
      return n unless n.empty?
      # cor do Dinabox sem nome no arquivo: o nome vem da própria imagem da cor (ex.: CARVALHO-EUROPEU-BON808c, Areal - 185x275)
      # (uma palavra só, tipo "Branco" ou "Preto", pode ser TX, Diamante… aí pergunta)
      n = nome_textura(mt); return n if n.split(/[\s\-]+/).size >= 2
    end
    ''
  end
  def self.nome_textura(mt)
    arq = (mt && mt.texture && mt.texture.filename).to_s.tr('\\', '/').split('/').last.to_s.sub(/\.[a-z0-9]+$/i, '')
    t = arq.sub(/[_\s-]*\d{2,4}\s*x\s*\d{2,4}\s*$/i, '').sub(/[_\s-]+(vert|hor|horizontal|vertical|[HV])\d*$/i, '')
    t = t.sub(/_[a-z]{10,}$/i, '').sub(/[_\s-]*(alb|albedo|diff|diffuse|col|color|1k|2k|4k)$/i, '').sub(/[_\s-]+\d+$/, '').strip
    return '' if t.empty? || t =~ /^(material|textura|texture|default|\d+)$/i
    t.tr('_', ' ').squeeze(' ').strip.then { |x| x[0].upcase + x[1..-1] }
  end
  def self.nome_cor(cod, mt, banco)
    n0 = nome_conhecido(cod, mt, banco); return n0 unless n0.empty?
    b = banco[cod]; return b['nome'] if b.is_a?(Hash) && !b['nome'].to_s.strip.empty?
    if cod.to_s =~ /^DB\d+$/i
      tx = File.join(Sketchup.find_support_file('Plugins'), 'DinaBox', 'materiais', "#{cod}.txt")
      n = (File.binread(tx).force_encoding('UTF-8')[/\[NOME\](.*?)\[\/NOME\]/m, 1].to_s.strip rescue '')
      return n unless n.empty?
    end
    arq = (mt && mt.texture && mt.texture.filename).to_s.tr('\\', '/').split('/').last.to_s.sub(/\.[a-z0-9]+$/i, '')
    t = arq.sub(/[_\s-]*\d{2,4}\s*x\s*\d{2,4}\s*$/i, '').tr('_', ' ').sub(/[\s-]*\d+$/, '').squeeze(' ').strip
    if t.empty? || t =~ /^(material|textura|texture|default)$/i
      t = cod.to_s =~ /^(DB\d+|sem material)$/i ? '' : cod.to_s.sub(/^[A-Z]\d{1,3}_/, '').tr('_', ' ').strip
    end
    return '' if t.empty?
    t[0].upcase + t[1..-1]
  end
  # veio: 1) banco  2) pelo nome (madeira x cor lisa)  3) pela imagem da textura (riscas numa direção = veio). nil = não sei, pergunta
  MADEIRAS = /carvalho|noce|nogueira|freij|cedro|am[eê]ndoa|louro|jequitib|teca|pinus|madeira|wood|oak|walnut|b[eé]tula|[eé]bano|cumaru|imbuia|tauari|mogno|castanh|cerejeira|marfim veio|rovere|olmo|lamina|l[aâ]mina|tabaco|canela|nature|ipe|ip[eê]|guanandi|sucupira|peroba|angelim|jatob/i
  LISAS = /branco|preto|cinza|grafite|azul|verde|amarelo|vermelho|rosa|bege|areia|fendi|\btx\b|ultra|laca|lacca|liso|chumbo|titanio|tit[aâ]nio|cristal|gelo|off ?white|nude|salvia|s[aá]lvia|terracota|stone|concreto|cimento|m[aá]rmore|granito/i
  def self.veio_auto(cod, mt, nome, banco)
    b = banco[cod]; return b['veio'] if b.is_a?(Hash) && [true, false].include?(b['veio']) && b['veio_fonte'] == 'voce'
    r = reg_cor(cod, banco); return r['veio'] if r && [true, false].include?(r['veio'])
    bc = base_cor(cod); banco.each { |k, v| return v['veio'] if v.is_a?(Hash) && v['veio_fonte'] == 'voce' && [true, false].include?(v['veio']) && base_cor(k) == bc }
    return b['veio'] if b.is_a?(Hash) && [true, false].include?(b['veio'])
    t = "#{nome} #{mt && mt.texture ? File.basename(mt.texture.filename.to_s) : ''}"
    return true if t =~ MADEIRAS
    return false if t =~ LISAS
    return false unless mt && mt.texture
    ir = mt.texture.image_rep; w = ir.width; h = ir.height
    n = [96, w - 2, h - 2].min; return nil if n < 16
    x0 = (w - n) / 2; y0 = (h - n) / 2
    g = Array.new(n) { |j| Array.new(n) { |i| c = ir.color_at_uv((x0 + i + 0.5) / w, (y0 + j + 0.5) / h); 0.3 * c.red + 0.59 * c.green + 0.11 * c.blue } }
    vals = g.flatten; med = vals.sum / vals.size; dp = Math.sqrt(vals.sum { |v| (v - med)**2 } / vals.size)
    return false if dp < 2.0
    dh = 0.0; dv = 0.0
    (0...n - 1).each { |j| (0...n - 1).each { |i| dh += (g[j][i + 1] - g[j][i]).abs; dv += (g[j + 1][i] - g[j][i]).abs } }
    r = [dh, dv].max / [[dh, dv].min, 0.01].max
    r >= 1.8 ? true : (r <= 1.3 ? false : nil)
  rescue
    nil
  end

  # nomes de cor (e veio) que você escolheu na tela vão para o banco (valem para todos os PCs)
  def self.gravar_cores(dados)
    mapa = dados.is_a?(Hash) && dados.key?('nomes') ? dados['nomes'] : dados
    veios = dados.is_a?(Hash) && dados['veio'].is_a?(Hash) ? dados['veio'] : {}
    banco = banco_cores; mudou = false
    veios.each { |cod, v| next unless [true, false].include?(v); banco[cod] = {} unless banco[cod].is_a?(Hash); next if banco[cod]['veio'] == v && banco[cod]['veio_fonte'] == 'voce'; banco[cod]['veio'] = v; banco[cod]['veio_fonte'] = 'voce'; mudou = true }
    mapa.each { |cod, nome| n = nome.to_s.strip; next if n.empty?; atual = banco[cod]; next if atual.is_a?(Hash) && atual['nome'] == n && atual['fonte'] == 'voce'; banco[cod] = (atual.is_a?(Hash) ? atual : {}).merge('nome' => n, 'fonte' => 'voce'); mudou = true }
    return unless mudou
    require 'fileutils'; f = banco_arquivo; FileUtils.mkdir_p(File.dirname(f))
    File.binwrite(f, JSON.pretty_generate(banco).b)
  rescue
    nil
  end

  # enviar = botão PCF · Nesting / menu: abre a página INÍCIO (todas as OSs). enviar(true) = fluxo direto do projeto aberto
  # (chamado pela própria página e pelos botões da tela do plano).
  def self.enviar(direto = false)
    unless direto
      inicio
      return
    end
    @projeto_externo = nil
    splash
    UI.start_timer(0.35, false) do
      begin
        enviar_ja
      rescue => e
        (@dlg.close rescue nil); UI.messagebox("PCF Label: erro ao abrir — #{e.message}")
      end
    end   # deixa a tela de carregamento aparecer antes do trabalho pesado
  end
  # peça "na tela": o olhar da câmera realmente a atinge em algum ponto da janela (raio de visão do próprio SketchUp,
  # já respeitando corte de seção, objetos ocultos da cena e o que está na frente). Só enquadrar não basta.
  def self.na_tela?(m, skpath)
    view = m.active_view
    cam = view.camera
    t = Geom::Transformation.new
    ent = nil
    # caminho da peça direto pelo SketchUp (<1 ms). Antes procurava cada nível pelo id, varrendo o projeto inteiro
    # (~0,3 s por peça: num projeto de 750 peças eram minutos antes de abrir o plano)
    ip = (m.instance_path_from_pid_path(skpath.to_s) rescue nil)
    if ip && ip.valid? && (lf = ip.to_a.last) && lf.respond_to?(:transformation)
      ent = lf
      t = ip.transformation
    else
      skpath.to_s.split('.').each do |id|
        ent = (m.find_entity_by_persistent_id(id.to_i) rescue nil)
        return true unless ent && ent.respond_to?(:transformation)   # não achou: não arrisca tirar
        t = t * ent.transformation
      end
    end
    b = ent.definition.bounds
    w = view.vpwidth.to_f; h = view.vpheight.to_f
    eye = cam.eye; dir = cam.direction
    xs = []; ys = []
    8.times do |k|
      p = b.corner(k).transform(t)
      next if (p - eye) % dir <= 0            # atrás da câmera
      s = view.screen_coords(p)
      xs << s.x; ys << s.y
    end
    return false if xs.empty?
    # corte de seção ativo (do modelo): o que fica do lado cortado (oposto à seta do plano) não aparece
    # (só se "Mostrar cortes de seção" estiver ligado: desligado, o corte não esconde nada)
    (m.rendering_options['DisplaySectionCuts'] == false ? [] : m.entities.grep(Sketchup::SectionPlane).select(&:active?)).each do |sp|
      a, bb, c, d = sp.get_plane
      cortada = (0..7).all? { |k| q = b.corner(k).transform(t); a * q.x + bb * q.y + c * q.z + d < 0 }
      return false if cortada
    end
    x0 = [xs.min, 0.0].max; x1 = [xs.max, w].min; y0 = [ys.min, 0.0].max; y1 = [ys.max, h].min
    return false if x0 > x1 || y0 > y1          # fora da janela
    # grade de raios dentro do retângulo projetado: basta um atingir a peça
    n = 9
    pts = []
    (0..n).each { |i| (0..n).each { |j| pts << [x0 + (x1 - x0) * i / n.to_f, y0 + (y1 - y0) * j / n.to_f] } }
    # linha de corte desenhada na frente da peça (recorte orgânico, moldura…) e linhas do Dinabox não tapam a peça: o raio passa por elas
    transparente = lambda do |cam|
      cam.any? { |e| (e.respond_to?(:get_attribute) && e.get_attribute('pcf', 'tipo') == 'linha_corte') || (e.respond_to?(:definition) && e.definition.name =~ /dinabox_polyline/i) }
    end
    pts.each do |x, y|
      ray = view.pickray(x, y)
      6.times do
        hit = m.raytest(ray, true)
        break unless hit && hit[1]
        return true if hit[1].include?(ent)
        break unless transparente.(hit[1])
        ray = [hit[0].offset(ray[1], 0.01.mm), ray[1]]
      end
    end
    false
  rescue StandardError
    true
  end

  # peça que virou tamponamento (atributo 'virou'): existe ainda o tamponamento? Procurar um id por vez varria o projeto
  # inteiro (~0,3 s CADA; 16 peças = 5 s). Agora junta todos, procura de uma vez e guarda por 5 s (vale a coleta inteira).
  def self.virou_existe?(vid)
    m = Sketchup.active_model
    id = vid.to_i
    agora = Time.now.to_f
    c = @virou_cache
    unless c && c[:guid] == m.guid && agora - c[:t] < 5 && c[:ids].key?(id)
      ids = {}
      m.definitions.each { |d| next if d.image?; d.instances.each { |e| v = e.get_attribute('pcf', 'virou'); ids[v.to_i] = false if v } }
      ids[id] = false
      lista = ids.keys
      ach = (m.find_entity_by_persistent_id(*lista) rescue nil)
      ach = [ach] unless ach.is_a?(Array)
      lista.each_with_index { |k, i| ids[k] = !ach[i].nil? }
      c = @virou_cache = { guid: m.guid, t: agora, ids: ids }
    end
    c[:ids][id]
  rescue StandardError
    !!(Sketchup.active_model.find_entity_by_persistent_id(vid.to_i) rescue nil)
  end

  # o que NÃO está na tela agora não entra no plano — ou você escolhe (Sim = só as da tela; Não = todas; Cancelar = nada)
  def self.filtrar_na_tela(m, pecas)
    fora = pecas.reject { |p| na_tela?(m, p[:skpath]) }
    return pecas if fora.empty?
    dentro = pecas.size - fora.size
    return pecas if dentro.zero?   # nenhuma na tela: faz com todas (antes o "Sim" fazia um plano vazio e a tela fechava)
    nomes = fora.map { |p| nome_limpo(p[:nome]).then { |x| x.empty? ? p[:nome].to_s : x } }.uniq.first(6).join(', ')
    msg = "#{fora.size} peça(s) não estão na tela agora (fora da vista ou de outra cena):\n#{nomes}#{fora.size > 6 ? '…' : ''}\n\n" \
          "Sim = plano só com as #{dentro} peça(s) que estão na tela\nNão = plano com todas as #{pecas.size}\nCancelar = não fazer o plano"
    r = UI.messagebox(msg, MB_YESNOCANCEL)
    return nil if r == IDCANCEL
    r == IDYES ? pecas - fora : pecas
  end

  def self.enviar_ja
    m = Sketchup.active_model
    pecas = []
    coletar(m.entities, Geom::Transformation.new, [], pecas)
    if pecas.empty?
      (@dlg.close rescue nil)
      UI.messagebox('PCF Label: nenhuma peça encontrada.')
      return
    end
    # só o que está na tela agora (cena/vista atual) — ou você escolhe
    pecas = filtrar_na_tela(m, pecas)
    if pecas.nil? || pecas.empty?
      (@dlg.close rescue nil)
      return
    end
    pecas = pecas.select { |p| p[:origem] == 'SketchUp' } + pecas.reject { |p| p[:origem] == 'SketchUp' }
    # móvel: peças dentro do mesmo grupo de fora (2 ou mais) = mesmo móvel, com um nº
    por_topo = pecas.group_by { |p| p[:topo] }
    num_movel = {}; k_m = 0
    pecas.each { |p| next if por_topo[p[:topo]].size < 2 || num_movel[p[:topo]]; k_m += 1; num_movel[p[:topo]] = k_m }
    # espessuras quase iguais (14,9 / 15) viram a mais comum
    cont = pecas.map { |p| p[:esp] }.tally
    pecas.each { |p| alvo = cont.select { |e, _| (e - p[:esp]).abs <= 0.3 }.max_by { |_, c| c }; p[:esp] = alvo[0] if alvo }
    lista = pecas.flat_map do |p|
      xs = p[:contorno].map(&:first); ys = p[:contorno].map(&:last); mx = xs.min; my = ys.min
      w = (xs.max - mx).round(2); h = (ys.max - my).round(2)
      mv = num_movel[p[:topo]]
      folha_txt = mv ? "Móvel #{mv}" : 'Avulsa'
      mae = { id: 'sk' + p[:sk], skpath: p[:skpath], folha: folha_txt, movel: mv, movelNome: (mv ? nome_limpo(p[:topo_nome]) : ''), origem: p[:origem], camada: p[:cam], c: [w, h].max.round(1), l: [w, h].min.round(1), dentro: false,
        x: 0, y: 0, w: w, h: h, pts: p[:contorno].map { |a, b| [(a - mx).round(2), (b - my).round(2)] }, furos: [],
        esp: p[:esp], mat: p[:mat], corInicial: "#{p[:mat]} #{p[:esp].to_s.sub(/\.0$/, '')}mm", nomeInicial: nome_limpo(p[:nome]), funcao: p[:auto].to_s, virada: p[:virada] }
      # furos e rebaixos viram "contornos dentro da peça": na lista você escolhe Furo / Rebaixo / Usinagem / Peça
      filho = lambda do |pts, k, tipo, prof, obs|
        q = pts.map { |a, b| [(a - mx).round(2), (b - my).round(2)] }
        qx = q.map(&:first); qy = q.map(&:last)
        { id: "sk#{p[:sk]}##{k}", pai: mae[:id], skpath: p[:skpath], folha: mae[:folha], origem: p[:origem], dentro: true, x: qx.min, y: qy.min, w: (qx.max - qx.min).round(2), h: (qy.max - qy.min).round(2),
          c: [qx.max - qx.min, qy.max - qy.min].max.round(1), l: [qx.max - qx.min, qy.max - qy.min].min.round(1), pts: q, furos: [], esp: p[:esp], mat: p[:mat],
          corInicial: mae[:corInicial], tipoInicial: tipo, profInicial: prof, obsInicial: obs, nomeInicial: '' }
      end
      fs = p[:furos].each_with_index.map { |fu, i| filho.(fu, "f#{i + 1}", 'furo', '', '') }
      rs = (p[:rebaixos] || []).each_with_index.map { |r, i| filho.(r[:pts], "r#{i + 1}", 'rebaixo', r[:prof], r[:lado] < 0 ? 'rebaixo no VERSO (virar a peça)' : '') }
      ls = (p[:linhas] || []).each_with_index.map do |r, i|
        c = filho.(r[:pts], "l#{i + 1}", 'usinagem', r[:passa] ? p[:esp] : r[:prof], r[:passa] ? 'corte entre as peças (Peça Mãe)' : 'marcação (Peça Mãe)')
        c.merge(linha: r[:linha].map { |a, b| [(a - mx).round(2), (b - my).round(2)] }, fresaD: r[:di], passa: r[:passa], pasInicial: (r[:pas] > 0 ? r[:pas] : nil), okInicial: true, ladoInicial: 'linha')
      end
      [mae] + fs + rs + ls
    end
    esp_comum = lista.map { |x| x[:esp] }.group_by(&:itself).max_by { |_, v| v.size }.first
    titulo = (m.title.to_s.strip.empty? ? 'SketchUp' : m.title.to_s.strip)
    # códigos de material usados: textura (nome do arquivo) e cor, para sugerir o nome da cor
    mats = {}
    banco = banco_cores
    pecas.map { |p| p[:mat] }.uniq.each do |cod|
      mt = m.materials[cod]
      arq = (mt && mt.texture && mt.texture.filename).to_s.tr('\\', '/')
      partes = arq.split('/').reject(&:empty?)
      cor = mt ? [mt.color.red, mt.color.green, mt.color.blue] : [200, 200, 200]
      foto = nil
      if mt && mt.texture
        begin
          pasta_t = File.join(ENV['TEMP'] || Dir.tmpdir, 'PCF_texturas')
          Dir.mkdir(pasta_t) unless Dir.exist?(pasta_t)
          ext = File.extname(arq)[/\.(jpe?g|png|bmp)$/i] ? File.extname(arq).downcase : '.png'
          arqf = File.join(pasta_t, cod.to_s.gsub(/[^\w\-]/, '_') + ext)
          mt.texture.write(arqf, false)
          foto = 'file:///' + arqf.tr('\\', '/').gsub(' ', '%20') if File.exist?(arqf)
        rescue StandardError
          foto = nil
        end
      end
      mats[cod] = { textura: (partes.last || '').sub(/\.[a-z0-9]+$/i, ''), pasta: partes[-3..-2].to_a.join(' / '), rgb: cor, foto: foto, nome: nome_conhecido(cod, mt, banco), sugestao: nome_cor(cod, mt, banco), veio: veio_auto(cod, mt, nome_cor(cod, mt, banco), banco) }
    end
    dados = { projeto: titulo, materiais: mats, espessura: esp_comum, chapa: '1850 x 2750', selecao: false,
              data: Time.now.strftime('%d/%m/%Y %H:%M'), origem: 'sketchup', pecas: lista, planoArq: (ler_plano rescue nil), bancoCores: banco_arquivo.to_s,
              compras: (lista_compras rescue []) }
    salvar_banco(banco, mats)
    unless File.exist?(MODELO_TELA)
      UI.messagebox("PCF Label: não achei a tela do PCF Label em\n#{MODELO_TELA}\nInstale o gadget PCF Label no Aspire.")
      return
    end
    @dados_vivos = copia(dados)          # o que está visível AGORA (para plano novo)
    UI.start_timer(4, false) { nuvem_subir rescue nil }
    if @pedido_novo then @pedido_novo = false; novo_plano; return "#{lista.size} peças no plano novo" end
    if @pedido_plano then id = @pedido_plano; @pedido_plano = nil; abrir_plano(id); return "plano #{id} aberto" end
    planos = listar_planos
    dados[:planos] = planos
    # já tem plano salvo: PERGUNTA se quer fazer um plano de corte novo ou abrir um plano já feito (✕ = abre o último)
    # sempre pergunta ao abrir (dá para abrir plano de outro cliente/OS pela lista da conta ☁)
    if !planos.empty? || !@abrir_novo_direto
      dados[:planoEscolhido] = false; dados[:inicio] = true
      mostrar(dados)
      return "#{planos.size} plano(s) salvo(s): escolha novo ou abrir"
    end
    (@excluidos ||= []).delete(nome_plano)
    dados[:planoId] = 'principal'; dados[:planoNome] = 'Plano principal'
    dados[:planoEscolhido] = true
    mostrar(dados)
    "#{lista.size} peças enviadas"
  end

  # ===================== PÁGINA INICIAL: todas as OSs com plano de corte =====================
  # Índice compartilhado (Dropbox > PCF Label > planos_indice.json): uma entrada por projeto (.skp), com cliente/OS/ambiente
  # (da pasta), data do último plano e a lista de planos. Atualizado a cada plano salvo; 🔄 Reindexar varre tudo.
  def self.indice_arquivo
    File.join(pasta_comum, 'planos_indice.json')
  end
  def self.indice_ler
    JSON.parse(File.read(indice_arquivo, encoding: 'UTF-8')) rescue {}
  end
  def self.indice_gravar(h)
    File.write(indice_arquivo, JSON.pretty_generate(h), mode: 'w:UTF-8')
  rescue StandardError => e
    puts "PCF Label índice: #{e.message}"
  end
  def self.chave_projeto(caminho)
    caminho.to_s.tr('\\', '/').sub(/\A[a-z]:/i) { |x| x.upcase }
  end
  # o mesmo projeto em PCs diferentes (C:/Users/PICHAU/... e C:/Users/Usuario/...): compara a partir da pasta do Dropbox
  def self.chave_rel(caminho)
    p = caminho.to_s.tr('\\', '/')
    i = p =~ %r{/[^/]*dropbox[^/]*/}i
    (i ? p[i..-1] : p).downcase
  end
  # junta as entradas repetidas do índice (mesmo projeto gravado por PCs diferentes): fica uma, com o caminho deste PC
  def self.indice_sem_repetidos(h)
    grupos = h.values.group_by { |e| chave_rel(e['skp']) }
    return [h, false] if grupos.size == h.size
    novo = {}
    grupos.each_value do |es|
      loc = es.map { |e| e.merge('skp' => caminho_local(e['skp'])) }
      base = loc.find { |e| File.exist?(e['skp'].to_s) } || loc.max_by { |e| e['mtime'].to_i }
      e2 = (File.exist?(base['skp'].to_s) ? (indice_entrada(base['skp']) rescue nil) : nil) || base
      e2['pasta'] = File.dirname(e2['skp'].to_s)
      novo[chave_projeto(e2['skp'])] = e2
    end
    [novo, true]
  end
  # planos de um projeto lidos da pasta dele (sem abrir o .skp)
  def self.planos_do_projeto(caminho)
    pth = caminho.to_s
    return [] if pth.empty? || !File.exist?(pth) && !Dir.exist?(File.dirname(pth))
    base = File.basename(pth, '.*') + '.pcfplano'
    dir = File.dirname(pth)
    (Dir.children(dir) rescue []).select { |n| n.start_with?(base) && n.end_with?('.json') }.map do |n|
      meio = n[base.size...-5]; id = meio.empty? ? 'principal' : meio.sub(/^\./, '')
      f = File.join(dir, n)
      o = (JSON.parse(File.read(f, encoding: 'UTF-8')) rescue nil)
      next nil unless o.is_a?(Hash)
      cr, ct = criado_de(o, [f])
      { 'id' => id, 'nome' => o['nome'] || (id == 'principal' ? 'Plano principal' : "Plano #{id}"), 'data' => o['data'].to_s, 'criado' => cr, 'ct' => ct, 'gerado' => (!o['gc'].nil? && o['gc'] != false), 'salvo' => !o['salvo'].to_s.empty?,
        'n' => o['n'], 'pecas' => (o['pecas'] ? o['pecas'].count { |p| !p['dentro'] } : nil), 'mtime' => File.mtime(f).to_i }
    end.compact.sort_by { |x| [x['ct'].to_i, x['id'] == 'principal' ? 0 : x['id'].to_i] }
  end
  def self.indice_entrada(caminho)
    planos = planos_do_projeto(caminho)
    return nil if planos.empty?
    info = info_pasta(caminho)
    # sem pasta de OS (ex.: 2026/Peças Aspire/Outubro/Allan Eccel): o nome da pasta vira o cliente
    cli = info[:cliente].to_s
    cli = File.basename(File.dirname(caminho.to_s)) if cli.empty? && info[:os].to_s.empty?
    { 'projeto' => File.basename(caminho, '.*'), 'skp' => caminho.to_s, 'pasta' => File.dirname(caminho.to_s),
      'cliente' => cli, 'os' => info[:os].to_s, 'amb' => info[:amb].to_s,
      'planos' => planos, 'mtime' => planos.map { |p| p['mtime'].to_i }.max,
      'data' => Time.at(planos.map { |p| p['mtime'].to_i }.max).strftime('%d/%m/%Y %H:%M') }
  end
  def self.indice_atualizar_projeto(caminho)
    return if caminho.to_s.empty?
    h = indice_ler
    e = indice_entrada(caminho)
    k = chave_projeto(caminho)
    cr = chave_rel(caminho)
    h.delete_if { |kk, ee| kk != k && chave_rel(ee['skp']) == cr } # o mesmo projeto gravado com o caminho de outro PC
    e ? h[k] = e : h.delete(k)
    indice_gravar(h)
  end
  # varredura completa da pasta da empresa (demora alguns segundos)
  def self.reindexar
    raiz = pasta_comum.to_s.sub(/[\\\/]PCF Label\z/, '')
    arqs = Dir.glob(File.join(raiz, '**', '*.pcfplano*.json'))
    h = {}
    arqs.map { |f| File.join(File.dirname(f), File.basename(f).sub(/\.pcfplano(\.[\w\-]+)?\.json\z/, '')) }.uniq.each do |base|
      skp = Dir.glob(base + '.skp').first || (base + '.skp')
      e = indice_entrada(skp)
      h[chave_projeto(skp)] = e if e
    end
    indice_gravar(h)
    h
  end
  # ---------- a página ----------
  def self.inicio
    h = indice_ler
    if h.empty?
      h = (reindexar rescue {})
    else
      # índice antigo, sem a data de criação dos planos: completa uma vez
      h, mudou = indice_sem_repetidos(h)
      velhos = h.select { |_k, e| Array(e['planos']).any? { |p| !p.key?('criado') } }
      velhos.each { |k, e| (n = indice_entrada(caminho_local(e['skp'].to_s)) rescue nil); (h[k] = n; mudou = true) if n }
      indice_gravar(h) if mudou
    end
    atual = chave_projeto(Sketchup.active_model.path)
    atual_r = chave_rel(Sketchup.active_model.path)
    linhas = h.values.map { |e| e.merge('atual' => chave_rel(e['skp']) == atual_r) }.sort_by { |e| [-(e['mtime'].to_i)] }
    dados = { linhas: linhas, atual: atual, projetoAberto: (Sketchup.active_model.title.to_s.empty? ? 'sem nome' : Sketchup.active_model.title.to_s),
              temPath: !Sketchup.active_model.path.to_s.empty?, indice: indice_arquivo }
    html = inicio_html.sub('__DADOS__') { JSON.generate(dados).gsub('</', '<\\/') }
    arq = File.join(ENV['TEMP'] || Dir.tmpdir, 'PCF Label - inicio.html')
    File.write(arq, html, mode: 'w:UTF-8')
    if @dlg_inicio && @dlg_inicio.visible?
      @dlg_inicio.set_file(arq); @dlg_inicio.bring_to_front; return
    end
    @dlg_inicio = UI::HtmlDialog.new(dialog_title: 'PCF Label - Início', preferences_key: 'PCFLabel.inicio', scrollable: true,
                                     resizable: true, width: 1100, height: 700, style: UI::HtmlDialog::STYLE_DIALOG)
    d = @dlg_inicio
    d.add_action_callback('novo') { |_c| (d.close rescue nil); enviar(true) }
    d.add_action_callback('abrir') do |_c, skp, id|
      begin
        skp = caminho_local(skp)
        (d.close rescue nil)
        if chave_projeto(skp) == chave_projeto(Sketchup.active_model.path)
          @projeto_externo = nil; @pedido_plano = id; enviar(true)
        else
          abrir_plano_externo(skp, id)
        end
      rescue => e
        UI.messagebox("PCF Label: não consegui abrir — #{e.message}")
      end
    end
    d.add_action_callback('pasta') { |_c, pasta| UI.openURL('file:///' + caminho_local(pasta)) rescue nil }
    d.add_action_callback('reindexar') { |_c| (reindexar rescue nil); inicio }
    d.add_action_callback('nuvem') { |_c, k| (d.close rescue nil); @projeto_externo = nil; splash rescue nil; UI.start_timer(0.3, false) { nuvem_abrir(k) } }
    d.add_action_callback('conta') { |_c| f = conta_pcf; f ? f.conta_janela : UI.messagebox('O login ainda não está instalado neste PC. Clique no ⬆ Atualizar da barra PCF.') }
    d.add_action_callback('pronto') { |_c| inicio_nuvem(d) }
    d.add_action_callback('excluir') { |_c, json| inicio_excluir(d, (JSON.parse(json.to_s) rescue {})) }
    d.set_file(arq)
    d.show
  end
  # chave do plano de um projeto (igual ao nome_plano quando ele está aberto)
  def self.chave_de_skp(skp)
    require 'digest/md5'
    t = File.basename(skp.to_s, '.*').gsub(/[\\\/:*?"<>|]/, '_')
    "#{t} ##{Digest::MD5.hexdigest(skp.to_s.downcase.tr('\\', '/'))[0, 6]}"
  end
  # 🗑 Início: exclui um plano — só com a SENHA da conta PCF (conferida no login; não fica guardada)
  # na conta fica marcado como excluído; os arquivos do plano vão para o histórico (dá para recuperar)
  def self.inicio_excluir(d, h)
    resp = ->(ok, msg, senha = false) { d.execute_script("exclResp(#{JSON.generate(ok: ok, msg: msg, senha: senha)})") rescue nil }
    skp = h['skp'].to_s.empty? ? '' : caminho_local(h['skp'])
    id = id_plano(h['id']); k = h['k'].to_s
    doc = k.empty? ? (skp.empty? ? nil : [doc_plano(chave_de_skp(skp), id, skp), doc_plano(chave_de_skp(skp), id)]) : k
    gerado_plano(skp, id, k) do |ger|
      conferir_senha(ger, h['senha']) do |ok, msg|
        next resp.(false, msg, ger) unless ok
        marcar_excluido_nuvem(doc) do |ok2, msg2|
          next resp.(false, msg2) unless ok2
          (inicio_arquivar(skp, id) rescue nil) unless skp.empty?
          resp.(true, 'Plano excluído.')
          UI.start_timer(0.3, false) { inicio rescue nil }
        end
      end
    end
  rescue => e
    resp.(false, "Erro: #{e.message}") rescue nil
  end
  def self.inicio_arquivar(skp, id)
    require 'fileutils'
    if chave_projeto(skp) == chave_projeto(Sketchup.active_model.path) && !@projeto_externo
      excluir_plano(id) # projeto aberto: a exclusão normal (a tela se ajusta)
    else
      suf = sufixo_plano(id); pd = pasta_planos; hist = File.join(pd, 'historico'); FileUtils.mkdir_p(hist)
      carimbo = Time.now.strftime('%Y-%m-%d %H-%M-%S'); chave = chave_de_skp(skp)
      [File.join(File.dirname(skp), File.basename(skp, '.*') + '.pcfplano' + suf + '.json'), File.join(pd, chave + suf + '.json')].each_with_index do |a, i|
        next unless File.exist?(a)
        FileUtils.mv(a, File.join(hist, chave + suf + ' ' + carimbo + (i > 0 ? " (excluído, cópia #{i})" : ' (excluído)') + '.json')) rescue nil
      end
    end
    indice_atualizar_projeto(skp)
  end
  # ☁ planos da CONTA (de todos os computadores) na página Início
  def self.inicio_nuvem(d)
    js = ->(h) { d.execute_script("addNuvem(#{JSON.generate(h).gsub('</', '<\\/')})") rescue nil }
    f = conta_pcf
    return js.(ok: false, msg: 'Login não instalado neste PC — clique no ⬆ Atualizar da barra PCF.') unless f
    c = conta_info
    return js.(ok: false, login: true, msg: 'Entre na sua conta (👤 Conta) para ver os planos de todos os computadores.') unless c
    nuvem_subir rescue nil
    campos = %w[chave id nome cliente os amb projeto skp data criado gerado salvo t pecas pc excluido]
    url0 = 'https://firestore.googleapis.com/v1/projects/os-moveis/databases/(default)/documents/' + "pcf_planos/#{c[:uid]}/itens?pageSize=300&" + campos.map { |x| "mask.fieldPaths=#{x}" }.join('&')
    tudo = []
    pagina = lambda do |tok|
      f.com_token do |ok|
        next js.(ok: false, msg: 'Sem internet ou a conta saiu.') unless ok
        cc = f.instance_variable_get(:@conta)
        f.http(Sketchup::Http::GET, url0 + (tok ? "&pageToken=#{tok}" : ''), nil, cc[:id]) do |s, dd|
          next js.(ok: false, msg: "A nuvem não respondeu (#{s}).") unless s == 200
          tudo += (dd['documents'] || []).map { |x| f.fs_doc(x).merge('k' => x['name'].to_s.split('/').last) }
          next pagina.call(dd['nextPageToken']) if dd['nextPageToken']
          js.(ok: true, email: cc[:email].to_s, lista: tudo.reject { |m| m['excluido'] })
        end
      end
    end
    pagina.call(nil)
  rescue => e
    js.(ok: false, msg: "Erro: #{e.message}") rescue nil
  end
  # abre o plano de OUTRA OS sem abrir o .skp dela: o plano guarda as próprias peças; o que você salvar vai para a pasta daquela OS
  # caminho salvo em OUTRO computador (ex.: C:/Users/Usuario/Projetos Zonta Dropbox/...): acha o mesmo arquivo neste PC
  # trocando o começo até a pasta do Dropbox pela pasta do Dropbox deste usuário
  def self.caminho_local(p)
    p = p.to_s.tr('\\', '/')
    return p if p.empty? || File.exist?(p)
    partes = p.split('/')
    i = partes.index { |x| x =~ /dropbox/i }
    return p unless i
    casa = (ENV['USERPROFILE'] || ENV['HOME'] || '').tr('\\', '/')
    [File.join(casa, *partes[i..-1]), *Dir.glob(File.join(casa, '*', *partes[i..-1]))].find { |x| File.exist?(x) } || p
  rescue
    p.to_s
  end
  def self.abrir_plano_externo(skp, id)
    skp = caminho_local(skp)
    @projeto_externo = skp.to_s
    id = id_plano(id)
    pl = ler_plano(id)
    unless pl
      @projeto_externo = nil
      return UI.messagebox("Não achei o plano #{id} de #{File.basename(skp)}.")
    end
    pecas = (pl['pecas'] || []).map { |p| p.transform_keys(&:to_sym) }
    banco = banco_cores
    mats = {}
    pecas.map { |p| p[:mat] }.compact.uniq.each do |cod|
      nm = (nome_cor(cod, nil, banco) rescue '')
      mats[cod] = { textura: '', pasta: '', rgb: [200, 200, 200], foto: nil, nome: (nome_conhecido(cod, nil, banco) rescue ''), sugestao: nm,
                    veio: (veio_auto(cod, nil, nm, banco) rescue nil) }
    end
    esp_comum = pecas.map { |p| p[:esp] }.compact.group_by(&:itself).max_by { |_, v| v.size }&.first || 18.3
    dados = { projeto: File.basename(skp, '.*'), materiais: mats, espessura: esp_comum, chapa: '1850 x 2750', selecao: false,
              data: Time.now.strftime('%d/%m/%Y %H:%M'), origem: 'sketchup', pecas: pecas, planoArq: pl, bancoCores: banco_arquivo.to_s,
              compras: (pl['compras'] || []), externo: true }
    @dados_vivos = copia(dados)
    splash
    UI.start_timer(0.3, false) do
      begin
        abrir_plano(id)
      rescue => e
        (@dlg.close rescue nil); UI.messagebox("PCF Label: erro ao abrir o plano — #{e.message}")
      end
    end
  end
  def self.inicio_html
    <<~'HTML'
      <!doctype html><html><head><meta charset="utf-8"><style>
      body{font:13px Segoe UI,Arial,sans-serif;margin:0;background:#f4f5f7;color:#1d2330}
      .topo{display:flex;gap:8px;align-items:center;padding:10px 14px;background:#fff;border-bottom:1px solid #dde1e7;position:sticky;top:0}
      .topo h2{margin:0;font-size:16px;flex:1}
      button{padding:7px 12px;border:1px solid #c5cad3;border-radius:6px;background:#fff;cursor:pointer;font-size:13px}
      button.p{background:#e8590c;color:#fff;border-color:#c74e0a;font-weight:600}
      button:active{transform:scale(.97)}
      input{padding:7px 10px;border:1px solid #c5cad3;border-radius:6px;width:260px}
      table{width:100%;border-collapse:collapse;background:#fff}
      th{position:sticky;top:52px;background:#f0f1f4;text-align:left;padding:8px 10px;font-size:12px;color:#555;border-bottom:1px solid #dde1e7;cursor:pointer}
      td{padding:8px 10px;border-bottom:1px solid #eceef2;vertical-align:middle}
      tr.atual td{background:#fff7ed}
      tr.cli td{background:#eef1f6;cursor:pointer;font-size:14px;padding:10px;border-top:2px solid #d5dae3}
      tr.cli:hover td{background:#e3e8f1}
      tr.cli.atual td{background:#ffedd5}
      tr.pj td:first-child{padding-left:26px}
      .seta{display:inline-block;width:14px;color:#e8590c}
      .badge{display:inline-block;padding:2px 8px;border-radius:10px;background:#e5e7eb;font-size:12px}
      .badge.m{background:#e8590c;color:#fff;font-weight:600}
      .sub{color:#6b7280;font-size:12px}
      .planos{display:flex;flex-direction:column;gap:3px;align-items:flex-start}
      .planos .pl{display:flex;align-items:center;gap:6px}
      .planos .pl button{white-space:nowrap}
      .planos .pl .qd{font-size:11px;color:#666;white-space:nowrap}
      .planos button{padding:4px 8px;font-size:12px}
      .planos button.nv{background:#eef6ff;border-color:#9cc3f5}
      .planos button.del{padding:4px 6px;color:#b3261e;margin-right:6px}
      #exclBox{position:fixed;inset:0;background:rgba(0,0,0,.45);display:flex;align-items:center;justify-content:center;z-index:99}
      #exclBox .cx{background:#fff;border-radius:12px;padding:18px 22px;width:360px;max-width:92%;box-shadow:0 10px 40px rgba(0,0,0,.3)}
      .nvb{display:inline-block;padding:1px 6px;border-radius:8px;background:#1f6feb;color:#fff;font-size:11px;margin-left:4px}
      #vazio{padding:30px;text-align:center;color:#6b7280}
      </style></head><body>
      <div class="topo"><h2>PCF Label — Início</h2>
        <input id="busca" placeholder="Buscar cliente, OS, ambiente, projeto…">
        <button id="abrirTodos" title="Abrir/fechar todos os clientes">⇕ Todos</button>
        <button class="p" id="novo">➕ Plano do projeto aberto</button>
        <button id="rasc" title="Planos que você não salvou (💾) nem gerou o G-code — o PCF guarda sozinho">📝 Rascunhos</button>
        <button id="reindexar" title="Varre todas as pastas da empresa (demora alguns segundos)">🔄 Reindexar</button>
      </div>
      <div id="nv" style="padding:6px 14px;background:#eef6ff;border-bottom:1px solid #d6e6fb;font-size:12px">☁ Buscando os planos da sua conta…</div>
      <table><thead><tr>
        <th data-k="mtime">Data</th><th data-k="cliente">Cliente ▾</th><th data-k="os">OS</th><th data-k="amb">Ambiente</th><th data-k="projeto">Projeto</th><th>Planos</th><th></th>
      </tr></thead><tbody id="corpo"></tbody></table>
      <div id="vazio" style="display:none">Nenhum plano de corte encontrado. Clique em 🔄 Reindexar.</div>
      <script>
      var D=__DADOS__; var ord='mtime', asc=false; var VER_RASC=false;
      // escrita sempre no mesmo padrão: Primeira Letra Maiúscula (de/da/do/e/em minúsculos), espaços certos, hífen com espaço
      var MIN={de:1,da:1,do:1,das:1,dos:1,e:1,em:1,no:1,na:1,nos:1,nas:1,com:1,para:1,a:1,o:1};
      function pad(t){ t=String(t==null?'':t).replace(/[_]+/g,' ').replace(/\s*-\s*/g,' - ').replace(/\s+/g,' ').trim(); if(!t) return t;
        return t.split(' ').map(function(w,i){ if(/\d/.test(w)||w=='-') return w.toUpperCase()==w?w:w; var l=w.toLocaleLowerCase('pt-BR'); if(i>0&&MIN[l]) return l; return l.replace(/[a-zà-ÿ]/,function(c){return c.toLocaleUpperCase('pt-BR');}); }).join(' '); }
      function padL(e){ e.cliente=pad(e.cliente); e.amb=pad(e.amb); e.projeto=pad(e.projeto); (e.planos||[]).forEach(function(p){p.nome=pad(p.nome);}); return e; }
      (D.linhas||[]).forEach(padL);
      function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
      // agrupado por CLIENTE: clique no nome do cliente para abrir/fechar os projetos dele
      var abertos={}; (D.linhas||[]).forEach(function(e){ if(e.atual) abertos[cliKey(e)]=true; });
      function cliKey(e){ return String(e.cliente||'').toLowerCase().replace(/\s+/g,' ').trim() || '~'; }
      function render(){
        var q=(document.getElementById('busca').value||'').toLowerCase();
        var L=D.linhas.filter(function(e){return !q||[e.cliente,e.os,e.amb,e.projeto,e.data].join(' ').toLowerCase().indexOf(q)>=0;});
        L.sort(function(a,b){var x=a[ord],y=b[ord];if(ord=='mtime'){x=+x;y=+y;}else{x=String(x).toLowerCase();y=String(y).toLowerCase();}return (x<y?-1:x>y?1:0)*(asc?1:-1);});
        var G={}, ordem=[];
        L=L.filter(function(e){return VER_RASC||e.planos.some(function(p){return p.gerado||p.salvo;});});
        L.forEach(function(e){var k=cliKey(e); if(!G[k]){G[k]={nome:e.cliente||'Sem cliente',linhas:[],mt:0,planos:0,atual:false};ordem.push(k);} var g=G[k]; g.linhas.push(e); g.mt=Math.max(g.mt,+e.mtime||0); g.planos+=e.planos.length; if(e.atual)g.atual=true;});
        if(ord=='cliente') ordem.sort(function(a,b){return (G[a].nome.toLowerCase()<G[b].nome.toLowerCase()?-1:1)*(asc?1:-1);});
        else if(ord=='mtime') ordem.sort(function(a,b){return (G[b].mt-G[a].mt)*(asc?-1:1);});
        var tb=document.getElementById('corpo');tb.innerHTML='';
        document.getElementById('vazio').style.display=L.length?'none':'block';
        ordem.forEach(function(k){
          var g=G[k], ab=!!q||!!abertos[k];
          var oss={}; g.linhas.forEach(function(e){ if(e.os) oss[e.os]=1; });
          var nos=Object.keys(oss).length, ult=g.linhas.reduce(function(m,e){return (+e.mtime||0)>(+m.mtime||0)?e:m;},g.linhas[0]);
          var h=document.createElement('tr'); h.className='cli'+(g.atual?' atual':''); h.dataset.cli=k;
          h.innerHTML='<td colspan="7"><span class="seta">'+(ab?'▾':'▸')+'</span> <b>'+esc(g.nome)+'</b>'+
            ' <span class="sub">· '+(nos?nos+(nos>1?' OSs':' OS')+' · ':'')+g.linhas.length+(g.linhas.length>1?' projetos':' projeto')+' · '+g.planos+(g.planos>1?' planos':' plano')+' · último: '+esc((ult&&ult.data)||'')+'</span>'+
            (g.atual?' <span class="badge">projeto aberto</span>':'')+'</td>';
          tb.appendChild(h);
          if(!ab) return;
          g.linhas.forEach(function(e){
            var tr=document.createElement('tr'); tr.className='pj'+(e.atual?' atual':'');
            var vis=e.planos.filter(function(p){return p.gerado||p.salvo||VER_RASC;}); var n=vis.length;
            if(!n) return;
            var pls=vis.map(function(p){var del='<button class="del" data-del="1" data-dk="'+esc(p.k||'')+'" data-dskp="'+esc(e.skp||'')+'" data-did="'+esc(p.id||'')+'" data-dger="'+(p.gerado?'1':'')+'" data-dnome="'+esc((p.nome||'Plano')+' · '+(e.cliente||'')+' · '+(e.projeto||''))+'" title="Excluir este plano (pede a senha da conta)">🗑</button>';
              var qd='<span class="qd">'+(p.gerado?'<b style="color:#1d7a46">✔ gerado</b> · ':p.salvo?'<b style="color:#1f5fbf">💾 salvo</b> · ':'<b style="color:#b8860b">📝 rascunho</b> · ')+(p.criado?'🕓 criado '+esc(p.criado):'')+(p.data?(p.criado?' · ':'')+'alterado '+esc(p.data):'')+(p.pecas!=null?' · '+p.pecas+' peças':'')+'</span>';
              return '<div class="pl">'+(p.k ? '<button class="nv" data-k="'+esc(p.k)+'" title="☁ da conta'+(p.pc?' · salvo no '+esc(p.pc):'')+' · '+esc(p.data||'')+(p.pecas!=null?' · '+p.pecas+' peças':'')+'">☁ '+esc(p.nome)+'</button>' : '<button data-skp="'+esc(e.skp)+'" data-id="'+esc(p.id)+'" title="'+esc(p.data||'')+(p.pecas!=null?' · '+p.pecas+' peças':'')+'">'+esc(p.nome)+'</button>')+qd+del+'</div>';}).join('');
            tr.innerHTML='<td>'+esc(e.data)+'</td><td></td><td>'+esc(e.os||'—')+'</td><td>'+esc(e.amb||'—')+'</td>'+
              '<td>'+esc(e.projeto)+(e.atual?' <span class="badge">aberto</span>':'')+(e.nuvem?'<span class="nvb">☁ nuvem</span>':'')+'<div class="sub">'+esc(e.pasta||'')+'</div></td>'+
              '<td><span class="badge'+(n>1?' m':'')+'">'+n+(n>1?' planos':' plano')+'</span></td>'+
              '<td><div class="planos">'+pls+(e.pasta?' <button data-pasta="'+esc(e.pasta)+'" title="Abrir a pasta do projeto">📁</button>':'')+'</div></td>';
            tb.appendChild(tr);
          });
        });
      }
      document.getElementById('busca').oninput=render;
      document.getElementById('rasc').onclick=function(){VER_RASC=!VER_RASC; this.textContent=VER_RASC?'📝 Esconder rascunhos':'📝 Rascunhos'; this.style.background=VER_RASC?'#fff3c4':''; render();};
      document.querySelectorAll('th[data-k]').forEach(function(th){th.onclick=function(){var k=th.dataset.k; if(ord==k)asc=!asc; else {ord=k;asc=(k!='mtime');} render();};});
      document.getElementById('corpo').onclick=function(ev){var hc=ev.target.closest('tr.cli');if(hc&&!ev.target.closest('button')){var k=hc.dataset.cli;abertos[k]=!abertos[k];render();return;}var b=ev.target.closest('button');if(!b)return; if(b.dataset.del){pedirSenha(b);return;} if(b.dataset.k){b.textContent='⏳ abrindo…';sketchup.nuvem(b.dataset.k);} else if(b.dataset.pasta)sketchup.pasta(b.dataset.pasta); else if(b.dataset.skp)sketchup.abrir(b.dataset.skp,b.dataset.id);};
      document.getElementById('novo').onclick=function(){sketchup.novo();};
      document.getElementById('abrirTodos').onclick=function(){var algum=Object.keys(abertos).some(function(k){return abertos[k];}); abertos={}; if(!algum) D.linhas.forEach(function(e){abertos[cliKey(e)]=true;}); render();};
      document.getElementById('reindexar').onclick=function(){this.textContent='⏳ Varrendo…';this.disabled=true;sketchup.reindexar();};
      // ☁ planos da conta (de todos os computadores): entram na lista; o que já está neste PC não repete
      function norm(s){return String(s||'').toLowerCase().replace(/\s+/g,' ').trim();}
      function addNuvem(r){
        var nv=document.getElementById('nv');
        if(!r.ok){nv.innerHTML='☁ '+esc(r.msg)+(r.login?' <button id="bConta">👤 Entrar</button>':''); var bc=document.getElementById('bConta'); if(bc)bc.onclick=function(){sketchup.conta();}; return;}
        var grupos={};
        r.lista.forEach(function(m){m.cliente=pad(m.cliente);m.amb=pad(m.amb);m.projeto=pad(m.projeto);m.nome=pad(m.nome);var g=grupos[m.chave]||(grupos[m.chave]={cliente:m.cliente,os:m.os,amb:m.amb,projeto:m.projeto,skp:m.skp,mtime:0,data:'',planos:[],nuvem:true,pasta:''});
          g.planos.push({k:m.k,id:m.id,nome:m.nome||'Plano',data:m.data,criado:m.criado,gerado:!!m.gerado,salvo:!!m.salvo,pecas:m.pecas,pc:m.pc}); var t=+m.t||0; if(t>g.mtime){g.mtime=Math.round(t>1e11?t/1000:t);g.data=m.data||'';}});
        var n=0;
        Object.keys(grupos).forEach(function(c){var g=grupos[c];
          var loc=D.linhas.find(function(e){return (g.skp&&e.skp&&norm(e.skp)==norm(g.skp)) || (norm(e.cliente)==norm(g.cliente)&&norm(e.os)==norm(g.os)&&norm(e.projeto)==norm(g.projeto));});
          if(loc){ g.planos.forEach(function(p){ if(!loc.planos.some(function(q){return norm(q.nome)==norm(p.nome);})) loc.planos.push(p); }); }
          else { D.linhas.push(g); n++; }
        });
        nv.innerHTML='☁ Conta <b>'+esc(r.email)+'</b> · '+r.lista.length+' plano(s) na nuvem (de todos os computadores)'+(n?' · '+n+' projeto(s) que não estão neste PC':'')+' — botões <b>☁</b> abrem direto da nuvem, mesmo com outro projeto aberto.';
        render();
      }
      // 🗑 excluir plano: só com a senha da conta PCF
      var EXB=null;
      function pedirSenha(b){ EXB=b; var bx=document.getElementById('exclBox'); if(bx)bx.remove();
        bx=document.createElement('div'); bx.id='exclBox';
        bx.innerHTML='<div class="cx"><h3 style="margin:0 0 6px;color:#b3261e">🗑 Excluir plano</h3><div style="margin-bottom:10px">'+esc(b.dataset.dnome)+'</div>'+
          '<div id="exclSenhaBox" style="display:'+(b.dataset.dger?'block':'none')+'"><label style="font-size:13px">✔ Plano gerado: senha da sua conta PCF</label><input type="password" id="exclSenha" style="width:100%;padding:8px;box-sizing:border-box;margin:4px 0 8px"></div>'+(b.dataset.dger?'':'<div style="font-size:13px;margin-bottom:6px">📝 Rascunho (sem G-code gerado): exclui sem senha.</div>')+
          '<div id="exclMsg" style="min-height:18px;font-size:13px"></div><div style="display:flex;gap:8px;justify-content:flex-end;margin-top:8px"><button id="exclNao">Cancelar</button> <button id="exclSim" style="background:#b3261e;color:#fff;border-color:#b3261e">Excluir</button></div></div>';
        document.body.appendChild(bx);
        var se=document.getElementById('exclSenha'), ok=document.getElementById('exclSim');
        var ir=function(){ var pede=document.getElementById('exclSenhaBox').style.display!=='none'; if(pede&&!se.value){document.getElementById('exclMsg').textContent='Digite a senha.';return;} ok.disabled=true; ok.textContent='conferindo…'; document.getElementById('exclMsg').textContent='';
          sketchup.excluir(JSON.stringify({k:b.dataset.dk, skp:b.dataset.dskp, id:b.dataset.did, senha:se.value})); se.value=''; };
        ok.onclick=ir; se.onkeydown=function(e){ if(e.key==='Enter')ir(); if(e.key==='Escape')bx.remove(); };
        document.getElementById('exclNao').onclick=function(){bx.remove();}; setTimeout(function(){se.focus();},30); }
      function exclResp(r){ var bx=document.getElementById('exclBox'); if(!bx)return;
        if(r.ok){ bx.remove(); if(EXB){ var x=EXB.closest('.pl'); if(x)x.remove(); else EXB.remove(); } return; }
        var ok=document.getElementById('exclSim'); ok.disabled=false; ok.textContent='Excluir'; var m=document.getElementById('exclMsg'); m.style.color='#b3261e'; m.textContent=r.msg||'Não excluí.'; if(r.senha)document.getElementById('exclSenhaBox').style.display='block'; document.getElementById('exclSenha').focus(); }
      render();
      if(window.sketchup&&sketchup.pronto)sketchup.pronto();
      </script></body></html>
    HTML
  end

  unless file_loaded?(__FILE__)
    cmd = UI::Command.new('PCF · Nesting') { PCFLabel.inicio }
    cmd.tooltip = 'PCF · Nesting'
    cmd.status_bar_text = 'Plano de corte · etiquetas · G-code'
    PCFLabel.por_icone(cmd, 'nesting', 'pcf.png')
    tb = UI.toolbar(PCFLabel::BARRA); tb.add_item(cmd); tb.show
    ObjectSpace.each_object(UI::Toolbar) { |t| t.hide if t.name == 'PCF Label' && t.visible? }   # barra antiga separada: tudo fica na barra PCF
    UI.menu('Extensions').add_item('PCF · Início (todas as OSs)') { PCFLabel.inicio }
    UI.menu('Extensions').add_item('PCF · Plano de corte') { PCFLabel.enviar(true) }
    UI.menu('Extensions').add_item('PCF · Numerar peças') { UI.messagebox(PCFLabel.numerar) }
    file_loaded(__FILE__)
  end
end

PCFLabel.instalar_tela
PCFLabel.botao_nomes
PCFLabel.botao_detalhamento
unless $pcf_tm_atual
  $pcf_tm_atual = true
  UI.start_timer(8, false) { PCFLabel.atualizar_sozinho }
  UI.start_timer(300, true) { PCFLabel.atualizar_sozinho }
end
# atualização NA HORA: confere a pasta do Dropbox a cada 5 s (só lê os arquivos quando a data deles muda)
# internet: confere a cada 1 min (troca o timer antigo sem precisar reabrir o SketchUp)
if $pcf_tm_online && $pcf_tm_online_int != 60
  (UI.stop_timer($pcf_tm_online) rescue nil); $pcf_tm_online = nil
end
unless $pcf_tm_online
  $pcf_tm_online_int = 60
  $pcf_tm_online = UI.start_timer(60, true) { (PCFLabel.checar_online rescue nil) }
  UI.start_timer(15, false) { (PCFLabel.checar_online rescue nil); (PCFLabel.espalhar_versao rescue nil) }
end
unless $pcf_tm_rapido
  $pcf_tm_rapido = UI.start_timer(5, true) { (PCFLabel.atualizar_rapido rescue nil) }
end
