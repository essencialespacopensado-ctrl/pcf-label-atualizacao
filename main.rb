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

  def self.coletar(ents, tr, cam, pecas, pai_bb = nil, pids = [], herd = nil, origem = nil)
    ents.each do |e|
      next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
      next if e.hidden? || !camada_visivel?(e.layer)
      next if e.get_attribute('pcf', 'nome') || e.name == 'PCF Nome'    # texto 3D do nome não é peça
      d = e.definition
      orig = origem || origem_de(e, d)
      t = tr * e.transformation
      filhos = d.entities.select { |x| (x.is_a?(Sketchup::Group) || x.is_a?(Sketchup::ComponentInstance)) && !x.get_attribute('pcf', 'nome') && x.name != 'PCF Nome' }
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
        # furos: buracos que aparecem nas duas faces (atravessam)
        buracos = ->(fc) { fc ? fc.loops.reject(&:outer?).map { |lp| lp.vertices.map { |vv| p2.(vv.position.transform(t)) } } : [] }
        cen = ->(pp) { [pp.sum { |q| q[0] } / pp.size, pp.sum { |q| q[1] } / pp.size] }
        dentro2 = ->(pt, pp) { c = false; j = pp.size - 1; pp.each_with_index { |q, i2| r = pp[j]; c = !c if ((q[1] > pt[1]) != (r[1] > pt[1])) && (pt[0] < (r[0] - q[0]) * (pt[1] - q[1]) / (r[1] - q[1]) + q[0]); j = i2 }; c }
        rebs2 = rebs.map { |r| { pts: r[:pts3].map { |p| p2.(p) }, prof: r[:prof], lado: (virar ? -r[:lado] : r[:lado]) } }
        furos = (buracos.(f) + buracos.(f_baixo && f_baixo[:f])).reject { |h| c = cen.(h); rebs2.any? { |r| dentro2.(c, r[:pts]) } }
        # o mesmo furo visto nas duas faces conta uma vez
        furos = furos.each_with_object([]) { |h, acc| c = cen.(h); acc << h unless acc.any? { |g| g2 = cen.(g); (g2[0] - c[0]).abs < 1 && (g2[1] - c[1]).abs < 1 } }
        mat = e.material ? e.material.display_name : (faces.map { |x| x.material && x.material.display_name }.compact.group_by(&:itself).max_by { |_, vv| vv.size }&.first)
        mat ||= herd
        auto = (orig == 'Dinabox' && papel_dinabox(d)) || papel(n, vs, pai_bb || Sketchup.active_model.bounds, esp)
        # móvel: no Dinabox é o módulo (moduloid); nos outros, o grupo de fora
        mod = orig == 'Dinabox' ? [e, d].map { |x| (x.get_attribute('dinabox', 'construtivo') || x.get_attribute('dinabox', 'component_id')).to_s[/moduloid,(\d+)/, 1] || x.get_attribute('dinabox', 'component_id') }.compact.first : nil
        topo_id = mod ? "dinabox-#{mod}" : (pids.first || e.persistent_id).to_s
        topo_nm = mod ? "Módulo Dinabox #{mod}" : (cam.first || nome).to_s
        pai_nome = cam.reverse.find { |c| !nome_limpo(c).empty? }
        auto = "#{auto} - #{nome_limpo(pai_nome)}" if pai_nome
        pecas << { sk: e.persistent_id.to_s, skpath: (pids + [e.persistent_id]).join('.'), cam: (cam + [nome]).join(' > '), nome: nome, auto: auto, mat: (mat || 'sem material').to_s, esp: esp, contorno: contorno, furos: furos, rebaixos: rebs2, virada: virar, origem: orig || 'SketchUp', topo: topo_id, topo_nome: topo_nm }
      elsif !filhos.empty?
        bb = Geom::BoundingBox.new; d.bounds.then { |b| 8.times { |k| bb.add(b.corner(k).transform(t)) } }
        coletar(d.entities, t, cam + [nome], pecas, bb, pids + [e.persistent_id], (e.material && e.material.display_name) || herd, orig)
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
  def self.abrir_tela(arquivo)
    if @dlg && @dlg.visible?
      @dlg.set_file(arquivo); @dlg.bring_to_front; return
    end
    @dlg = UI::HtmlDialog.new(dialog_title: 'PCF Label - plano de corte', preferences_key: 'PCFLabel.tela', scrollable: true,
                              resizable: true, width: 1400, height: 900, style: UI::HtmlDialog::STYLE_DIALOG)
    callbacks(@dlg)
    @dlg.set_on_closed { restaurar_vista rescue nil }
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
    tb = UI.toolbar('PCF Label')
    cn = UI::Command.new('Ocultar / mostrar números') { PCFLabel.alternar_nomes }
    cn.tooltip = 'PCF Label: ocultar / mostrar os números das peças'
    cn.status_bar_text = 'Liga e desliga a etiqueta "PCF Nomes" (os números em cima das peças)'
    cn.set_validation_proc { (l = Sketchup.active_model.layers[PCFLabel::ETIQ]) && !l.visible? ? MF_UNCHECKED : MF_CHECKED }
    ic2 = File.join(File.dirname(__FILE__), 'pcf_nomes.png')
    if File.exist?(ic2) then cn.small_icon = ic2; cn.large_icon = ic2 end
    tb.add_item(cn); tb.show
    UI.menu('Extensions').add_item(cn)
  end

  # botão "Detalhamento": cria as cenas e monta o LayOut no padrão Zonta
  def self.botao_detalhamento
    return if $pcf_botao_det
    $pcf_botao_det = true
    tb = UI.toolbar('PCF Label')
    cd = UI::Command.new('Detalhamento (cenas + LayOut)') { PCFLabel.detalhar }
    cd.tooltip = 'PCF Label: criar cenas e o detalhamento no LayOut (padrão Zonta)'
    cd.status_bar_text = 'Cria as cenas das paredes e monta o LayOut com cotas e números dos painéis, e salva o PDF'
    ic = File.join(File.dirname(__FILE__), 'pcf_det.png')
    if File.exist?(ic) then cd.small_icon = ic; cd.large_icon = ic end
    tb.add_item(cd); tb.show
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
      if e.respond_to?(:name=) && e.name != nome then e.name = nome; n += 1 end
      begin
        pc = nil
        if c[0].length > 1
          tp = Geom::Transformation.new; c[0][0..-2].each { |x| tp = tp * x.transformation }
          bp = Geom::BoundingBox.new; c[0][-2].definition.bounds.then { |b0| 8.times { |k| bp.add(b0.corner(k).transform(tp)) } }
          pc = bp.center
        end
        if e.definition.count_instances == 1
          texto3d(e.definition.entities, e, c[1], nome, tag, mt, ref, pc)
        else
          # componente repetido: o texto fica no modelo, na posição desta cópia
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
    if ref.start_with?('PLANO_EXCLUIR:') then UI.start_timer(0.1, false) { excluir_plano(ref.sub('PLANO_EXCLUIR:', '')) }; return true end
    if ref.start_with?('PLANO_ABRIR:') then UI.start_timer(0.1, false) { abrir_plano(ref.sub('PLANO_ABRIR:', '')) }; return true end
    # plano novo e lista de planos: lê de novo o que está visível AGORA (não o da hora que abriu a tela)
    if ref == 'PLANO_NOVO' then UI.start_timer(0.1, false) { @pedido_novo = true; enviar }; return true end
    if ref == 'PLANO_LISTA' then UI.start_timer(0.1, false) { enviar }; return true end
    if ref == 'HIST'
      h = File.join(pasta_planos, 'historico')
      arqs = Dir.glob(File.join(h, '*.json').tr('\\', '/')).select { |x| File.basename(x).start_with?(nome_plano + sufixo_plano(@plano_id) + ' ') }.sort_by { |x| File.mtime(x) }.last(60)
      lista = arqs.map { |x| { arq: File.basename(x), quando: File.mtime(x).strftime('%d/%m %H:%M'), txt: File.binread(x).force_encoding('UTF-8') } }
      @dlg.execute_script("receberVersoes(#{JSON.generate(lista).gsub('</', '<\\/')})") rescue nil
      return true
    end
    if ref.start_with?('DIAG')
      File.binwrite(File.join(ENV['APPDATA'], 'PCF Label', 'diag.json'), ref[4..-1].to_s.b) rescue nil
      return true
    end
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
  def self.nome_plano
    m = Sketchup.active_model
    t = (m.title.to_s.empty? ? 'sem nome' : m.title.to_s).gsub(/[\\\/:*?"<>|]/, '_')
    # dois projetos com o MESMO nome em pastas diferentes (ex.: "Projeto Técnico 01.skp" de clientes diferentes) não podem
    # dividir o mesmo arquivo de plano: o nome leva um código da pasta do projeto
    pth = m.path.to_s
    return t if pth.empty?
    require 'digest/md5'
    "#{t} ##{Digest::MD5.hexdigest(pth.downcase.tr('\\', '/'))[0, 6]}"
  end
  # ---- vários planos no mesmo projeto: "principal" (o de sempre) e Plano 2, 3… (cada um com as próprias peças) ----
  def self.id_plano(id) t = id.to_s.strip; (t.empty? || t == 'principal') ? 'principal' : t.gsub(/[^\w\-]/, '_') end
  def self.sufixo_plano(id) id_plano(id) == 'principal' ? '' : ".#{id_plano(id)}" end
  def self.arq_plano_modelo(id = 'principal')
    pth = Sketchup.active_model.path.to_s
    pth.empty? ? nil : File.join(File.dirname(pth), File.basename(pth, '.*') + '.pcfplano' + sufixo_plano(id) + '.json')
  end
  def self.salvar_plano(txt)
    require 'fileutils'
    txt = txt.to_s.dup.force_encoding('UTF-8')
    return if txt.strip.empty?
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
    JSON.parse(File.read(cands.max_by { |x| File.mtime(x) }, encoding: 'UTF-8')) rescue nil
  end
  def self.listar_planos
    pth = Sketchup.active_model.path.to_s
    ids = []
    unless pth.empty?
      base = File.basename(pth, '.*') + '.pcfplano'
      Dir.children(File.dirname(pth)).each { |n| next unless n.start_with?(base) && n.end_with?('.json'); meio = n[base.size...-5]; ids << (meio.empty? ? 'principal' : meio.sub(/^\./, '')) }
    end
    pd = pasta_planos
    Dir.children(pd).each { |n| next unless n.start_with?(nome_plano) && n.end_with?('.json'); meio = n[nome_plano.size...-5]; ids << (meio.empty? ? 'principal' : meio.sub(/^\./, '')) if meio.empty? || meio.start_with?('.') } rescue nil
    ids.uniq.map do |id|
      o = ler_plano(id); next nil unless o
      { id: id, nome: o['nome'] || (id == 'principal' ? 'Plano principal' : "Plano #{id}"), data: o['data'], n: o['n'], t: o['t'],
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
    i = partes.rindex { |x| x =~ /^\s*\d{2}\.\d{3}\s*-\s*\S/ }
    return {} unless i
    os, amb = partes[i].split(/\s*-\s*/, 2).map(&:strip)
    cli = i > 0 ? partes[i - 1].sub(/^[\s\-]*\d+\s*[.\-]\s*/, '').strip : ''
    { cliente: cli, os: os, amb: amb.to_s }
  rescue
    {}
  end
  def self.mostrar(dados)
    dados[:pastaInfo] ||= info_pasta(Sketchup.active_model.path)
    dados[:projetoChave] = (nome_plano rescue nil)
    dados[:cfgComum] = (JSON.parse(File.read(File.join(pasta_comum, 'config.json'), encoding: 'UTF-8')) rescue nil)
    (checar_atualizacao(true) rescue nil)   # se tiver versão nova, instala sozinho
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
    pth = Sketchup.active_model.path.to_s
    unless pth.empty?
      base = File.basename(pth, '.*') + '.pcfplano'
      re2 = /\A#{Regexp.escape(base)}(\.[\w\-]+)?\.json\z/
      arqs += Dir.children(File.dirname(pth)).select { |n| n =~ re2 }.map { |n| File.join(File.dirname(pth), n) }
    end
    arqs.each_with_index do |f, i|
      FileUtils.mv(f, File.join(h, nome_plano + ' ' + carimbo + " (reiniciado do zero #{i + 1})" + '.json')) rescue (File.delete(f) rescue nil)
    end
    @excluidos = []; @plano_id = 'principal'
    enviar
  rescue => e
    UI.messagebox("Não consegui reiniciar: #{e.message}") rescue nil
  end
  # exclui um plano: os arquivos vão para o histórico (dá para recuperar em "Versões"), não some de vez
  def self.excluir_plano(id)
    require 'fileutils'
    id = id_plano(id); suf = sufixo_plano(id); pd = pasta_planos; h = File.join(pd, 'historico'); FileUtils.mkdir_p(h)
    (@excluidos ||= []) << nome_plano + suf
    carimbo = Time.now.strftime('%Y-%m-%d %H-%M-%S')
    [File.join(pd, nome_plano + suf + '.json'), arq_plano_modelo(id)].compact.each_with_index do |f, i|
      next unless File.exist?(f)
      FileUtils.mv(f, File.join(h, nome_plano + suf + ' ' + carimbo + (i > 0 ? " (excluído, cópia #{i})" : ' (excluído)') + '.json')) rescue (File.delete(f) rescue nil)
    end
    if id == @plano_id
      @dados_vivos ? (planos = listar_planos; planos.empty? ? enviar : abrir_plano(planos.max_by { |x| x[:t].to_i }[:id])) : enviar
    else
      @dlg.execute_script("planosAtualizados(#{JSON.generate(listar_planos).gsub('</', '<\\/')})") rescue nil
    end
  rescue => e
    UI.messagebox("Não consegui excluir o plano: #{e.message}") rescue nil
  end
  def self.abrir_plano(id)
    return unless @dados_vivos
    id = id_plano(id)
    (@excluidos ||= []).delete(nome_plano + sufixo_plano(id))
    d = copia(@dados_vivos)
    pl = ler_plano(id)
    if pl
      d[:pecas] = copia(pl['pecas']) if pl['pecas'].is_a?(Array) && !pl['pecas'].empty?
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
    require 'win32ole'
    procs = (WIN32OLE.connect('winmgmts://').ExecQuery("select CommandLine from Win32_Process where Name='powershell.exe'").each.map { |p| p.CommandLine.to_s } rescue nil)
    return if procs.nil? || procs.any? { |c| c =~ /botao\.ps1/i }
    WIN32OLE.new('WScript.Shell').Run('wscript.exe "' + BOTAO_VBS + '"', 0, false) if File.exist?(BOTAO_VBS)
  rescue
    nil
  end

  def self.vigiar
    @n_vigia = (@n_vigia || 0) + 1
    PCFLabel.garantir_botao if @n_vigia % 8 == 1
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
    sleep 0.5
    html = File.read(MODELO_TELA, encoding: 'UTF-8').sub('__DADOS__') { @dados_json }
    File.write(@saida, html, mode: 'w:UTF-8')
    @dlg.set_file(@saida)
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
  PLUGIN_VERSAO = '2026-10-15.09'
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
  def self.checar_online
    u = url_online; return unless u
    return if @online_ocupado; @online_ocupado = true
    baixar(u + 'versao.json') do |txt|
      begin
        man = txt && (JSON.parse(txt.dup.force_encoding('UTF-8')) rescue nil)
        vt_atual = versao_arq(MODELO_TELA, /VERSAO = '([^']+)'/)
        if man && (man['tela'].to_s > vt_atual || man['plugin'].to_s > PLUGIN_VERSAO)
          arqs = (man['arquivos'] || ['etiquetas.html', 'main.rb']); baixados = {}
          pega = lambda do |i|
            if i >= arqs.size
              require 'fileutils'; require 'tmpdir'
              tmp = File.join(ENV['TEMP'] || Dir.tmpdir, 'pcf_atualizacao'); FileUtils.mkdir_p(tmp)
              baixados.each { |n, b| File.binwrite(File.join(tmp, n), b) }
              @pa_online = tmp; aplicar_atualizacao(tmp)
              info = { tela: man['tela'], telaAtual: vt_atual, plugin: man['plugin'], pluginAtual: PLUGIN_VERSAO, notas: (man['notas'] || []).first(30) }
              UI.start_timer(4, false) { (@dlg.execute_script("mostrarAtualizado(#{JSON.generate(info).gsub('</', '<\\/')})") rescue nil) if @dlg }
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
        (File.write(@saida, File.read(MODELO_TELA, encoding: 'UTF-8').sub('__DADOS__') { @dados_json }, mode: 'w:UTF-8'); @mt_tela = File.mtime(MODELO_TELA); @dlg.set_file(@saida); log_atu('tela recarregada')) rescue log_atu("erro ao recarregar: #{$!.message}")
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

  def self.enviar
    m = Sketchup.active_model
    pecas = []
    coletar(m.entities, Geom::Transformation.new, [], pecas)
    if pecas.empty?
      UI.messagebox('PCF Label: nenhuma peça encontrada.')
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
      [mae] + fs + rs
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
              data: Time.now.strftime('%d/%m/%Y %H:%M'), origem: 'sketchup', pecas: lista, planoArq: (ler_plano rescue nil), bancoCores: banco_arquivo.to_s }
    salvar_banco(banco, mats)
    unless File.exist?(MODELO_TELA)
      UI.messagebox("PCF Label: não achei a tela do PCF Label em\n#{MODELO_TELA}\nInstale o gadget PCF Label no Aspire.")
      return
    end
    @dados_vivos = copia(dados)          # o que está visível AGORA (para plano novo)
    if @pedido_novo then @pedido_novo = false; novo_plano; return "#{lista.size} peças no plano novo" end
    planos = listar_planos
    dados[:planos] = planos
    # já tem plano salvo: abre direto o último que você usou (sem tela de escolha). Outro plano / plano novo: botão 🗂 Planos
    unless planos.empty?
      ult = planos.max_by { |x| x[:t].to_i }
      abrir_plano(ult[:id])
      return "#{ult[:nome]} aberto"
    end
    (@excluidos ||= []).delete(nome_plano)
    dados[:planoId] = 'principal'; dados[:planoNome] = 'Plano principal'
    dados[:planoEscolhido] = true
    mostrar(dados)
    "#{lista.size} peças enviadas"
  end

  unless file_loaded?(__FILE__)
    cmd = UI::Command.new('PCF → Aspire') { PCFLabel.enviar }
    cmd.tooltip = 'PCF Label: otimizar as peças modeladas e abrir no Aspire'
    cmd.status_bar_text = 'Envia todas as peças visíveis para o otimizador do PCF Label'
    ico = File.join(File.dirname(__FILE__), 'pcf.png')
    if File.exist?(ico) then cmd.small_icon = ico; cmd.large_icon = ico end
    tb = UI::Toolbar.new('PCF Label'); tb.add_item(cmd); tb.show
    UI.menu('Extensions').add_item('PCF Label → Aspire') { PCFLabel.enviar }
    UI.menu('Extensions').add_item('PCF Label → numerar peças') { UI.messagebox(PCFLabel.numerar) }
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
unless $pcf_tm_online
  $pcf_tm_online = UI.start_timer(600, true) { (PCFLabel.checar_online rescue nil); (PCFLabel.espalhar_versao rescue nil) }
  UI.start_timer(15, false) { (PCFLabel.checar_online rescue nil); (PCFLabel.espalhar_versao rescue nil) }
end
unless $pcf_tm_rapido
  $pcf_tm_rapido = UI.start_timer(5, true) { (PCFLabel.atualizar_rapido rescue nil) }
end
