# PCF Label - gerador de cenas + detalhamento no LayOut, no padrão Zonta (DETALHAMENTO.pdf)
#   A4 deitado · moldura 0,5 pt · faixa cinza #CCCCCC no topo · carimbo Verdana 10
#   cotas vermelhas #CC0000 0,35 pt com pontinho e número Arial 11 em fundo branco
#   nº do painel Verdana negrito 14 em quadro branco · capa com título Verdana 48 vermelho #FF261E e logo ZONTA
module PCFLabel
  module Detalhar
    IN = 25.4
    PW = 297.0; PH = 210.0
    VERM = [204, 0, 0]; TIT = [255, 38, 30]
    TAG = 'PCF Detalhamento'

    def self.c(r, g, b) Sketchup::Color.new(r, g, b) end
    def self.p2(x, y) Geom::Point2d.new(x / IN, y / IN) end
    def self.b2(x, y, w, h) Geom::Bounds2d.new(x / IN, y / IN, w / IN, h / IN) end
    def self.mm(pt2) [pt2.x * IN, pt2.y * IN] end

    def self.st(h)
      s = Layout::Style.new
      (s.stroked = !h[:sem_traco]) rescue nil
      s.stroke_color = h[:traco] if h[:traco]
      s.stroke_width = h[:esp] if h[:esp]
      if h[:fundo] then s.solid_filled = true; s.fill_color = h[:fundo] else s.solid_filled = false end
      s.font_family = h[:fonte] || 'Verdana'
      s.font_size = h[:tam] if h[:tam]
      s.text_bold = !!h[:negrito]
      s.text_color = h[:cor] || c(0, 0, 0)
      s.text_alignment = h[:alinha] if h[:alinha]
      s
    end

    def self.add(e, pg) @doc.add_entity(e, @lay, pg); e rescue (@erros << "add: #{$!.message}"; nil) end

    def self.ret(pg, x, y, w, h, o = {})
      r = Layout::Rectangle.new(b2(x, y, w, h)); r.style = st(o); add(r, pg)
    end

    # texto numa caixa (x,y = canto de cima à esquerda) ou centralizado num ponto
    def self.txt(pg, s, x, y, w, h, o = {})
      t = Layout::FormattedText.new(s, b2(x, y, w, h)); t.style = st(o); add(t, pg)
    rescue => e
      @erros << "texto #{s}: #{e.message}"; nil
    end
    def self.txt_c(pg, s, x, y, o = {})
      t = Layout::FormattedText.new(s, p2(x, y), Layout::FormattedText::ANCHOR_TYPE_CENTER_CENTER)
      t.style = st(o); add(t, pg)
      if o[:girar]
        (t.transform!(Geom::Transformation2d.rotation(p2(x, y), o[:girar])) rescue nil)
      end
      t
    rescue => e
      @erros << "texto #{s}: #{e.message}"; nil
    end

    def self.linha(pg, x1, y1, x2, y2, cor = VERM, esp = 0.35)
      l = Layout::Path.new(p2(x1, y1), p2(x2, y2)); l.style = st(traco: c(*cor), esp: esp); add(l, pg)
    rescue => e
      @erros << "linha: #{e.message}"
    end
    def self.ponto(pg, x, y)
      r = 0.21   # mm (~1,2 pt de diâmetro, igual ao seu)
      el = Layout::Ellipse.new(b2(x - r, y - r, 2 * r, 2 * r)); el.style = st(traco: c(*VERM), esp: 0.35, fundo: c(*VERM)); add(el, pg)
    rescue
      nil
    end

    # ---- cota no seu padrão: linha vermelha, linhas de chamada, pontinhos e número Arial 11 em fundo branco ----
    def self.cota_h(pg, x1, x2, y, valor, ref_y1 = nil, ref_y2 = nil)
      linha(pg, x1, y, x2, y)
      # linhas de chamada: da peça até um pouco acima da cota
      [[x1, ref_y1], [x2, ref_y2]].each { |x, ry| if ry then linha(pg, x, ry - 0.8, x, y - 2.0) else linha(pg, x, y - 2.0, x, y + 2.0) end; ponto(pg, x, y) }
      txt_c(pg, valor.to_s, (x1 + x2) / 2.0, y - 2.6, fonte: 'Arial', tam: 11, fundo: c(255, 255, 255), sem_traco: true)
    end
    def self.cota_v(pg, x, y1, y2, valor, ref_x = nil)
      linha(pg, x, y1, x, y2)
      [y1, y2].each { |y| linha(pg, ref_x || x - 2.0, y, x + 2.0, y) if ref_x; ponto(pg, x, y) }
      txt_c(pg, valor.to_s, x, (y1 + y2) / 2.0, fonte: 'Arial', tam: 11, fundo: c(255, 255, 255), sem_traco: true, girar: Math::PI / 2)
    end

    # ---- moldura + carimbo iguais ao seu PDF ----
    def self.moldura(pg, info, capa = false)
      ret(pg, 5, 5, 287, 5, fundo: c(204, 204, 204), traco: c(0, 0, 0), esp: 0.5)
      ret(pg, 5, 10, 287, 195, traco: c(0, 0, 0), esp: 0.5)
      ret(pg, 5, 190, 287, 15, traco: c(0, 0, 0), esp: 1.0)
      txt(pg, "Responsável:#{info[:resp]}", 7.6, 193.6, 110, 4.6, tam: 10)
      txt(pg, "Data:#{info[:data]}", 7.6, 197.8, 110, 4.6, tam: 10)
      txt(pg, info[:cliente], 88.5, 190.3, 120, 4.6, tam: 10, negrito: true, alinha: Layout::Style::ALIGN_CENTER)
      txt(pg, 'CLIENTE', 88.5, 194.5, 120, 4.6, tam: 10, alinha: Layout::Style::ALIGN_CENTER)
      if capa
        lg = File.join(__dir__, 'pcf_logo.png')
        (add(Layout::Image.new(lg, b2(250.3, 192.1, 38.9, 11.3)), pg) if File.exist?(lg)) rescue nil
      else
        txt(pg, 'TÉCNICO - MARCENARIA', 199.1, 191.4, 90, 4.6, tam: 10, negrito: true, alinha: Layout::Style::ALIGN_RIGHT)
        txt(pg, info[:amb], 199.1, 195.6, 90, 4.6, tam: 10, negrito: true, alinha: Layout::Style::ALIGN_RIGHT)
        txt(pg, info[:os], 199.1, 199.8, 90, 4.6, tam: 10, negrito: true, alinha: Layout::Style::ALIGN_RIGHT)
      end
    end

    # ---- peças do corte (as mesmas do plano: só MDF visível) com posição no mundo ----
    def self.pecas(m)
      lista = []; PCFLabel.coletar(m.entities, Geom::Transformation.new, [], lista)
      lista.map do |p|
        cm = PCFLabel.caminho(p[:skpath]); next unless cm
        inst = cm[0].last; t = cm[1]; d = inst.definition
        bb = Geom::BoundingBox.new; 8.times { |k| bb.add(d.bounds.corner(k).transform(t)) }
        f = d.entities.grep(Sketchup::Face).max_by(&:area); next unless f
        n = f.normal.transform(t); next if n.length == 0
        n.normalize!
        num = inst.name.to_s[/\APainel\s+(\d+)/i, 1] || inst.name.to_s[/\A(\d+)\b/, 1]
        { inst: inst, path: cm[0], t: t, bb: bb, n: n, c: bb.center, num: num }
      end.compact
    end

    # paredes: peças em pé com a mesma direção e no mesmo plano (perto umas das outras)
    def self.paredes(ps)
      em_pe = ps.select { |p| p[:n].z.abs < 0.25 }
      em_pe.each do |p|
        a = (Math.atan2(p[:n].y, p[:n].x) * 180 / Math::PI) % 180
        p[:ang] = (a / 10.0).round * 10 % 180
        rad = p[:ang] * Math::PI / 180; p[:nn] = Geom::Vector3d.new(Math.cos(rad), Math.sin(rad), 0)
        p[:d] = (p[:c] - ORIGIN) % p[:nn]
        u = Z_AXIS * p[:nn]; xs = (0..7).map { |k| (p[:bb].corner(k) - ORIGIN) % u }
        p[:u0] = xs.min; p[:u1] = xs.max
      end
      pai = {}; em_pe.each { |p| pai[p] = p }
      raiz = ->(p) { p = pai[p] while pai[p] != p; p }
      em_pe.combination(2).each do |a, b|
        next unless a[:ang] == b[:ang] && (a[:d] - b[:d]).abs < 400.mm
        gap = [a[:u0], b[:u0]].max - [a[:u1], b[:u1]].min
        pai[raiz.(a)] = raiz.(b) if gap < 400.mm
      end
      em_pe.group_by { |p| raiz.(p) }.values
           .select { |g| g.size >= 2 || g.any? { |p| (p[:u1] - p[:u0]) * (p[:bb].max.z - p[:bb].min.z) > (0.4 * 1550) } }
           .sort_by { |g| -g.size }.first(10)
    end

    # de que lado olhar a parede: o lado de onde mais números aparecem (raytest começando no plano da frente)
    def self.lado(m, g)
      n = g.first[:nn]
      [1, -1].map do |s|
        nv = Geom::Vector3d.new(n.x * s, n.y * s, 0)
        frente = g.map { |p| (0..7).map { |k| (p[:bb].corner(k) - ORIGIN) % nv }.max }.max
        vis = g.count { |p| visivel?(m, p, p[:c].offset(nv, frente - ((p[:c] - ORIGIN) % nv) + 5.mm), nv.reverse) }
        [vis, nv, frente]
      end.max_by(&:first)
    end
    def self.visivel?(m, p, origem, dir)
      r = (m.raytest([origem, dir], true) rescue nil)
      r && r[1].include?(p[:inst])
    end

    # ---- cenas ----
    def self.cena(m, nome, cam, secao = nil)
      v = m.active_view; v.camera = cam
      m.entities.active_section_plane = secao rescue nil
      (secao.activate rescue nil) if secao
      pg = m.pages.add(nome)
      pg.use_camera = true
      (pg.use_section_planes = true) rescue nil
      (pg.use_hidden_layers = true) rescue nil
      (pg.use_rendering_options = true) rescue nil
      pg
    end

    def self.gerar
      m = Sketchup.active_model
      if m.path.to_s.empty?
        UI.messagebox('Salve o projeto (.skp) antes de gerar o detalhamento.'); return
      end
      @erros = []
      info0 = PCFLabel.info_pasta(m.path)
      info = { cliente: info0[:cliente].to_s.upcase, os: info0[:os].to_s.empty? ? '' : "OS #{info0[:os]}", amb: info0[:amb].to_s.upcase,
               resp: Sketchup.read_default('PCFLabel', 'responsavel', 'Paulo C. Da Fonseca'), data: Time.now.strftime('%d/%m/%Y') }
      ps = pecas(m)
      if ps.empty? then UI.messagebox('Nenhuma peça de MDF visível para detalhar.'); return end
      grupos = paredes(ps)
      Sketchup.status_text = 'PCF: criando cenas…'

      # ---- 1) cenas no SketchUp ----
      m.start_operation('PCF: cenas do detalhamento', true)
      tag = m.layers[TAG] || m.layers.add(TAG)
      vis_tag = tag.visible?; tag.visible = false
      nomes = m.layers[PCFLabel::ETIQ]; vis_nomes = nomes ? nomes.visible? : nil
      nomes.visible = false if nomes                         # números 3D ficam fora das cenas do LayOut
      ro = m.rendering_options; sp_antes = ro['DisplaySectionPlanes']; ro['DisplaySectionPlanes'] = false
      cam0 = m.active_view.camera; cam_ant = Sketchup::Camera.new(cam0.eye, cam0.target, cam0.up, cam0.perspective?, cam0.fov)
      m.pages.to_a.select { |p| p.name =~ /\APCF D\d+ / }.each { |p| m.pages.erase(p) }   # cenas antigas do gerador
      todos = Geom::BoundingBox.new; ps.each { |p| todos.add(p[:bb]) }
      ce = todos.center; diag = todos.diagonal
      dir = Geom::Vector3d.new(-0.9, -1.25, 0.95).normalize
      cap = Sketchup::Camera.new(ce.offset(dir, diag * 1.6), ce, Z_AXIS, true, 35.0)
      m.active_view.camera = cap; m.active_view.zoom_extents rescue nil
      cena(m, 'PCF D01 CAPA', m.active_view.camera)
      folhas = []
      grupos.each_with_index do |g, i|
        _, nv, frente = lado(m, g)
        bb = Geom::BoundingBox.new; g.each { |p| bb.add(p[:bb]) }
        cg = bb.center
        alvo = cg.offset(nv, frente - ((cg - ORIGIN) % nv))
        # corte logo na frente da parede: a seta (normal) aponta para a parede, que fica visível; o que está na frente some
        sec = m.entities.add_section_plane([alvo.offset(nv, 3.mm), nv.reverse]); sec.layer = tag
        cam = Sketchup::Camera.new(alvo.offset(nv, diag * 2), alvo, Z_AXIS, false)
        (cam.height = [bb.max.z - bb.min.z, bb.diagonal].max * 1.15) rescue nil
        n_el = format('%02d', i * 2 + 2)
        nums = g.map { |p| p[:num] }.compact.map(&:to_i).sort
        titulo = "ELEVAÇÃO #{i + 1}" + (nums.empty? ? '' : " — PAINÉIS #{nums.first(14).join(', ')}#{nums.size > 14 ? '…' : ''}")
        cena(m, "PCF D#{n_el} ELEVACAO #{i + 1}", cam, sec)
        lat = Z_AXIS * nv
        d3 = (nv + Geom::Vector3d.new(lat.x * 0.75, lat.y * 0.75, 0.55)).normalize
        c3 = Sketchup::Camera.new(cg.offset(d3, bb.diagonal * 1.9), cg, Z_AXIS, true, 35.0)
        cena(m, "PCF D#{format('%02d', i * 2 + 3)} 3D #{i + 1}", c3, sec)
        folhas << { g: g, nv: nv, frente: frente, titulo: titulo, el: "PCF D#{n_el} ELEVACAO #{i + 1}", d3: "PCF D#{format('%02d', i * 2 + 3)} 3D #{i + 1}", olho3d: c3.eye }
      end
      m.entities.active_section_plane = nil rescue nil
      m.active_view.camera = cam_ant
      ro['DisplaySectionPlanes'] = sp_antes; tag.visible = vis_tag; nomes.visible = vis_nomes if nomes
      m.commit_operation
      m.save
      Sketchup.status_text = 'PCF: montando o LayOut…'

      # ---- 2) LayOut ----
      saida = pasta_saida(m, info)
      @doc = Layout::Document.new
      @doc.page_info.width = PW / IN; @doc.page_info.height = PH / IN
      (%w[left_margin right_margin top_margin bottom_margin].each { |k| @doc.page_info.send("#{k}=", 0.0) }) rescue nil
      @lay = @doc.layers.first
      idx = ->(nome) { m.pages.to_a.index { |p| p.name == nome } }

      # capa
      pg = @doc.pages.first; pg.name = 'CAPA'
      vp = Layout::SketchUpModel.new(m.path, b2(29.7, 16.3, 242.0, 138.6)); add(vp, pg)
      prep(vp, idx.('PCF D01 CAPA'))
      txt_c(pg, [info[:os], info[:amb]].reject(&:empty?).join(' '), 148.5, 181.5, tam: 48, cor: c(*TIT))
      moldura(pg, info, true)

      folhas.each_with_index do |fl, i|
        pg = @doc.pages.add("ELEVAÇÃO #{i + 1}")
        # elevação (esquerda) e 3D da mesma parede (direita)
        ax, ay, aw, ah = 14.0, 22.0, 168.0, 160.0
        vp = Layout::SketchUpModel.new(m.path, b2(ax, ay, aw, ah)); add(vp, pg)
        prep(vp, idx.(fl[:el]))
        escala(vp, fl, aw, ah)
        anotar_elevacao(m, pg, vp, fl, ax, ay, aw, ah)
        v3 = Layout::SketchUpModel.new(m.path, b2(190.0, 22.0, 98.0, 98.0)); add(v3, pg)
        prep(v3, idx.(fl[:d3]))
        numeros_3d(m, pg, v3, fl, [190.0, 22.0, 98.0, 98.0])
        txt_c(pg, fl[:titulo], 148.5, 15.2, tam: 10, fundo: c(255, 255, 255), sem_traco: true)
        moldura(pg, info)
      end

      @doc.save(saida)
      pdf = saida.sub(/\.layout\z/, '.pdf')
      Sketchup.status_text = 'PCF: exportando o PDF…'
      begin
        @doc.export(pdf, { 'output_resolution' => Layout::PageInfo::RESOLUTION_MEDIUM, 'compress_images' => true, 'compress_quality' => 0.75 })
      rescue
        (@doc.export(pdf) rescue @erros << "PDF: #{$!.message}")
      end
      Sketchup.status_text = ''
      msg = "Detalhamento pronto (#{folhas.size + 1} folhas):\n#{saida}\n#{pdf}"
      msg += "\n\nAvisos: #{@erros.uniq.first(6).join(' | ')}" unless @erros.empty?
      UI.messagebox(msg)
      UI.openURL('file:///' + pdf.tr('\\', '/').gsub(' ', '%20')) if File.exist?(pdf)
    rescue => e
      (m.abort_operation rescue nil)
      UI.messagebox("PCF Detalhamento: #{e.message}\n#{e.backtrace.first(3).join("\n")}")
    end

    def self.prep(vp, i)
      vp.current_scene = i + 1 if i      # 0 = última vista salva; as cenas começam em 1
      (vp.render_mode = Layout::SketchUpModel::RASTER_RENDER) rescue nil
      (vp.render if vp.render_needed?) rescue nil
    end

    # escala de marcenaria (1:10, 1:20, 1:25…) que caiba na área
    def self.escala(vp, fl, aw, ah)
      bb = Geom::BoundingBox.new; fl[:g].each { |p| bb.add(p[:bb]) }
      u = Z_AXIS * fl[:nv]
      ew = (0..7).map { |k| (bb.corner(k) - ORIGIN) % u }.minmax.reduce { |a, b| b - a }.to_mm
      eh = (bb.max.z - bb.min.z).to_mm
      fit = [(aw - 26) / [ew, 1].max, (ah - 22) / [eh, 1].max].min
      esc = [5, 10, 15, 20, 25, 30, 40, 50, 75, 100, 125, 150, 200].find { |k| 1.0 / k <= fit } || 200
      vp.scale = 1.0 / esc
      a = vp.model_to_paper_point(bb.center); b = vp.model_to_paper_point(bb.center.offset(u, 1000.mm))
      vp.scale = esc.to_f if ((a.distance(b) * IN) - 1000.0 / esc).abs > 1000.0 / esc * 0.2
    rescue => e
      @erros << "escala: #{e.message}"
    end

    def self.proj(vp, pt) mm(vp.model_to_paper_point(pt)) end

    # cotas (largura de cada painel em cima, altura de cada painel e altura total) + nº de cada painel
    def self.anotar_elevacao(m, pg, vp, fl, ax, ay, aw, ah)
      u = Z_AXIS * fl[:nv]
      frentes = fl[:g].select { |p| (p[:n] % fl[:nv]).abs > 0.9 }
      caixas = frentes.map do |p|
        q = (0..7).map { |k| proj(vp, p[:bb].corner(k)) }
        xs = q.map(&:first); ys = q.map(&:last)
        larg = (0..7).map { |k| (p[:bb].corner(k) - ORIGIN) % u }.minmax.reduce { |a, b| b - a }.to_mm.round
        alt = (p[:bb].max.z - p[:bb].min.z).to_mm.round
        { p: p, x0: xs.min, x1: xs.max, y0: ys.min, y1: ys.max, larg: larg, alt: alt }
      end
      return if caixas.empty?
      dentro = ->(x, y) { x > ax - 1 && x < ax + aw + 1 && y > ay - 1 && y < ay + ah + 1 }
      caixas.select! { |k| dentro.(k[:x0], k[:y0]) && dentro.(k[:x1], k[:y1]) }
      return if caixas.empty?
      # larguras em corrente, por cima de tudo
      topo = caixas.map { |k| k[:y0] }.min
      yc = [topo - 6.0, ay + 3].max
      vistos = []
      caixas.sort_by { |k| k[:x0] }.each do |k|
        next if k[:x1] - k[:x0] < 3
        next if vistos.any? { |a, b| (a - k[:x0]).abs < 1.5 && (b - k[:x1]).abs < 1.5 }
        vistos << [k[:x0], k[:x1]]
        cota_h(pg, k[:x0], k[:x1], yc, k[:larg], k[:y0], k[:y0])
      end
      # altura de cada painel, por dentro, perto da borda esquerda
      caixas.each do |k|
        next if k[:y1] - k[:y0] < 18 || k[:x1] - k[:x0] < 8
        cota_v(pg, k[:x0] + 3.5, k[:y0], k[:y1], k[:alt])
      end
      # altura total, do lado direito
      x_dir = [caixas.map { |k| k[:x1] }.max + 7.0, ax + aw + 4].min
      y0 = caixas.map { |k| k[:y0] }.min; y1 = caixas.map { |k| k[:y1] }.max
      bbz = fl[:g].map { |p| p[:bb] }
      tot = (bbz.map { |b| b.max.z }.max - bbz.map { |b| b.min.z }.min).to_mm.round
      cota_v(pg, x_dir, y0, y1, tot, x_dir - 4.0) if y1 - y0 > 10
      # números dos painéis (só os que aparecem de frente)
      caixas.each do |k|
        p = k[:p]; next unless p[:num]
        orig = p[:c].offset(fl[:nv], fl[:frente] - ((p[:c] - ORIGIN) % fl[:nv]) + 2.mm)
        next unless visivel?(m, p, orig, fl[:nv].reverse)
        x, y = proj(vp, p[:c])
        txt_c(pg, p[:num].to_s, x, y, tam: 14, negrito: true, fundo: c(255, 255, 255), sem_traco: true)
      end
    end

    def self.numeros_3d(m, pg, vp, fl, area)
      ax, ay, aw, ah = area
      fl[:g].each do |p|
        next unless p[:num]
        dirv = p[:c] - fl[:olho3d]; next if dirv.length == 0
        r = (m.raytest([fl[:olho3d], dirv], true) rescue nil)
        next unless r && r[1].include?(p[:inst])
        x, y = proj(vp, p[:c])
        next unless x > ax + 3 && x < ax + aw - 3 && y > ay + 3 && y < ay + ah - 3
        txt_c(pg, p[:num].to_s, x, y, tam: 14, negrito: true, fundo: c(255, 255, 255), sem_traco: true)
      end
    rescue => e
      @erros << "3D: #{e.message}"
    end

    # salva em <OS>\Projeto Tecnico (ou na pasta do skp)
    def self.pasta_saida(m, info)
      partes = m.path.tr('\\', '/').split('/')
      i = partes.rindex { |x| x =~ /^\s*\d{2}\.\d{3}\s*-\s*\S/ }
      base = i ? partes[0..i].join('/') : File.dirname(m.path)
      pt = (Dir.children(base).find { |x| x =~ /\Aprojeto\s*t[eé]cnico\z/i && File.directory?(File.join(base, x)) } rescue nil)
      dir = pt ? File.join(base, pt) : File.dirname(m.path)
      nome = "#{info[:amb].empty? ? File.basename(m.path, '.skp') : info[:amb]} - DETALHAMENTO"
      # se o arquivo estiver aberto no LayOut (travado), salva com outro nome
      livre = ->(a) { !File.exist?(a) || (File.open(a, 'r+') { true } rescue false) }
      arq = File.join(dir, nome + '.layout'); k = 2
      until livre.(arq) && livre.(arq.sub(/\.layout\z/, '.pdf')) || k > 50
        arq = File.join(dir, "#{nome} (#{k}).layout"); k += 1
      end
      arq
    end
  end
end
