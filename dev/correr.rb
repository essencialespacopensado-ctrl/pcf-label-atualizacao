# encoding: UTF-8
# PCF Ferramentas - Biblioteca de Correr
# Trilhos e sistemas de correr (Rometal RO-65, Häfele Slido, Dominus) e portas de alumínio.
# Selecione o módulo, escolha o sistema e o nº de portas: o PCF calcula as portas, desenha trilhos/portas
# e grava os itens de compra (aparecem na lista de materiais do PCF Label e no relatório do Dinabox).
# Porta de alumínio: gera um projeto .skp separado por módulo com as cenas Frontal e Traseira cotadas.
require 'json'

module PCF
  module Ferramentas
    # catálogo padrão (mm). Tudo editável na janela; o que você mudar fica salvo neste PC.
    # regras: altura da porta = altura de referência + alt_add; largura = (largura de referência + transpasse*(n-1)) / n + larg_add
    CATALOGO_CORRER = [
      { 'id' => 'dominus', 'marca' => 'Rometal', 'nome' => 'Dominus (porta suspensa)', 'tipo' => 'mdf',
        'obs' => 'Porta 90 mm maior que a caixa (55 em cima, 35 embaixo); cada porta 20 mm maior que o vão. Portas de 15 a 25 mm, mín. 600 mm de largura, até 80 kg.',
        'alt_add' => 90, 'desce' => 35, 'transpasse' => 0, 'larg_add' => 20, 'prof_trilho' => 45, 'alt_trilho' => 45,
        'trilho_sup' => 'RM-264', 'trilho_inf' => 'RM-265', 'barras' => [2000, 3000],
        'kit' => [['DOMINUS-KIT', 'Kit sistema Dominus (carros, guias e amortecedores)', 'kit', 1]],
        'por_porta' => [['DOMINUS-AMORT', 'Amortecedor Dominus', 'un', 2]] },
      { 'id' => 'ro65', 'marca' => 'Rometal', 'nome' => 'RO-65 (porta de correr)', 'tipo' => 'mdf',
        'obs' => 'Portas até 60 kg, 15 a 25 mm. Transpasse 20 a 30 mm. Folga de altura: CONFERIR no catálogo.',
        'alt_add' => -40, 'desce' => 0, 'transpasse' => 25, 'larg_add' => 0, 'prof_trilho' => 35, 'alt_trilho' => 20,
        'trilho_sup' => 'RO-65 sup.', 'trilho_inf' => 'RO-65 inf.', 'barras' => [2000, 3000],
        'kit' => [],
        'por_porta' => [['RO65-KIT', 'Kit RO-65 por porta (2 carros, 2 freios, 2 guias)', 'kit', 1]] },
      { 'id' => 'slido40', 'marca' => 'Häfele', 'nome' => 'Slido Classic 40 (até 40 kg)', 'tipo' => 'mdf',
        'obs' => 'Porta de 16 a 25 mm. Transpasse e folga de altura: CONFERIR no catálogo Häfele.',
        'alt_add' => -38, 'desce' => 0, 'transpasse' => 30, 'larg_add' => 0, 'prof_trilho' => 40, 'alt_trilho' => 20,
        'trilho_sup' => 'Slido trilho sup.', 'trilho_inf' => 'Slido trilho inf.', 'barras' => [2500, 3000],
        'kit' => [],
        'por_porta' => [['SLIDO40-KIT', 'Kit Slido Classic 40 por porta', 'kit', 1]] },
      { 'id' => 'slido80', 'marca' => 'Häfele', 'nome' => 'Slido Classic 80 (até 80 kg)', 'tipo' => 'mdf',
        'obs' => 'Porta de 16 a 25 mm. Transpasse e folga de altura: CONFERIR no catálogo Häfele.',
        'alt_add' => -38, 'desce' => 0, 'transpasse' => 30, 'larg_add' => 0, 'prof_trilho' => 40, 'alt_trilho' => 20,
        'trilho_sup' => 'Slido trilho sup.', 'trilho_inf' => 'Slido trilho inf.', 'barras' => [2500, 3000],
        'kit' => [],
        'por_porta' => [['SLIDO80-KIT', 'Kit Slido Classic 80 por porta', 'kit', 1]] },
      { 'id' => 'alu_correr', 'marca' => 'Serralheria', 'nome' => 'Porta de alumínio de correr (vidro)', 'tipo' => 'aluminio',
        'obs' => 'Quadro em perfil de alumínio com vidro, no trilho RO-65 (troque os códigos abaixo se usar outro). Gera o projeto da porta (Frontal e Traseira cotadas).',
        'alt_add' => -40, 'desce' => 0, 'transpasse' => 25, 'larg_add' => 0, 'prof_trilho' => 35, 'alt_trilho' => 20,
        'perfil_larg' => 37, 'perfil_prof' => 21, 'vidro_esp' => 4, 'vidro_encaixe' => 10,
        'trilho_sup' => 'RO-65 sup.', 'trilho_inf' => 'RO-65 inf.', 'barras' => [2000, 3000],
        'kit' => [],
        'por_porta' => [['RO65-KIT', 'Kit RO-65 por porta (2 carros, 2 freios, 2 guias)', 'kit', 1]] },
      { 'id' => 'alu_giro', 'marca' => 'Serralheria', 'nome' => 'Porta de alumínio de giro (vidro)', 'tipo' => 'aluminio',
        'obs' => 'Quadro em perfil de alumínio com vidro, de abrir (dobradiça). Gera o projeto da porta (Frontal e Traseira cotadas).',
        'alt_add' => -6, 'desce' => -3, 'transpasse' => -3, 'larg_add' => 0, 'prof_trilho' => 0, 'alt_trilho' => 0,
        'perfil_larg' => 37, 'perfil_prof' => 21, 'vidro_esp' => 4, 'vidro_encaixe' => 10,
        'trilho_sup' => '', 'trilho_inf' => '', 'barras' => [],
        'kit' => [],
        'por_porta' => [['DOBR-ALU', 'Dobradiça para perfil de alumínio', 'un', 2]] }
    ].freeze unless defined?(CATALOGO_CORRER)

    # porta de alumínio: modelos de perfil (mm), cores e vidros. Editáveis na janela (ficam salvos neste PC).
    ALU_PADRAO = {
      'perfis' => [
        { 'nome' => 'Perfil padrão 37 mm', 'larg' => 37, 'prof' => 21 },
        { 'nome' => 'Perfil slim 20 mm', 'larg' => 20, 'prof' => 20 },
        { 'nome' => 'Perfil largo 45 mm', 'larg' => 45, 'prof' => 21 },
        { 'nome' => 'Perfil puxador integrado 37 mm', 'larg' => 37, 'prof' => 25 }
      ],
      'cores' => [
        { 'nome' => 'Natural fosco', 'rgb' => [190, 194, 200] },
        { 'nome' => 'Preto fosco', 'rgb' => [38, 38, 40] },
        { 'nome' => 'Bronze', 'rgb' => [112, 86, 60] },
        { 'nome' => 'Champagne', 'rgb' => [201, 181, 140] },
        { 'nome' => 'Branco', 'rgb' => [240, 240, 238] },
        { 'nome' => 'Inox escovado', 'rgb' => [168, 170, 172] }
      ],
      'vidros' => [
        { 'nome' => 'Incolor', 'rgb' => [200, 226, 236], 'alpha' => 0.3 },
        { 'nome' => 'Fumê', 'rgb' => [85, 90, 96], 'alpha' => 0.55 },
        { 'nome' => 'Bronze', 'rgb' => [150, 110, 72], 'alpha' => 0.5 },
        { 'nome' => 'Reflecta prata', 'rgb' => [182, 188, 194], 'alpha' => 0.7 },
        { 'nome' => 'Canelado', 'rgb' => [210, 226, 232], 'alpha' => 0.5 },
        { 'nome' => 'Jateado', 'rgb' => [232, 236, 238], 'alpha' => 0.85 },
        { 'nome' => 'Espelho', 'rgb' => [214, 219, 224], 'alpha' => 1.0 }
      ],
      # puxador: comp = comprimento (0 = sem puxador; -1 = altura toda da porta), borda = do lado da porta até o centro,
      # centro = altura do centro do puxador a partir da base da porta
      'puxadores' => [
        { 'nome' => 'Sem puxador', 'comp' => 0, 'borda' => 0, 'centro' => 0 },
        { 'nome' => 'Puxador barra 300 mm', 'comp' => 300, 'borda' => 40, 'centro' => 1000 },
        { 'nome' => 'Puxador barra 600 mm', 'comp' => 600, 'borda' => 40, 'centro' => 1000 },
        { 'nome' => 'Puxador perfil altura toda', 'comp' => -1, 'borda' => 20, 'centro' => 0 }
      ],
      # dobradiça (porta de giro): do topo e da base até o centro; qtd 0 = automática pela altura
      'dobradicas' => [
        { 'nome' => 'Dobradiça para perfil alumínio', 'topo' => 100, 'base' => 100, 'qtd' => 0 },
        { 'nome' => 'Dobradiça caneco 35 (perfil largo)', 'topo' => 100, 'base' => 100, 'qtd' => 0 }
      ]
    }.freeze unless defined?(ALU_PADRAO)

    class << self
      def alu_opcoes
        o = (JSON.parse(Sketchup.read_default('PCF_Ferramentas', 'correr_alu', '').to_s) rescue nil)
        pad = JSON.parse(JSON.generate(ALU_PADRAO))
        return pad unless o.is_a?(Hash)
        pad.each_key { |k| o[k] = pad[k] unless o[k].is_a?(Array) && !o[k].empty? } # listas novas entram com o padrão
        o
      end

      def catalogo_correr
        salvo = (JSON.parse(Sketchup.read_default('PCF_Ferramentas', 'correr_catalogo', '[]').to_s) rescue [])
        base = JSON.parse(JSON.generate(CATALOGO_CORRER))
        salvo.each do |s|
          i = base.index { |b| b['id'] == s['id'] }
          i ? base[i] = base[i].merge(s) : base << s
        end
        base
      end

      def correr_salvar_sistema(s)
        salvo = (JSON.parse(Sketchup.read_default('PCF_Ferramentas', 'correr_catalogo', '[]').to_s) rescue [])
        salvo.reject! { |x| x['id'] == s['id'] }
        salvo << s
        Sketchup.write_default('PCF_Ferramentas', 'correr_catalogo', JSON.generate(salvo))
      end

      # módulo selecionado: medidas (mm) e transformação até o mundo
      def correr_alvo
        m = model
        e = m.selection.to_a.find { |x| x.is_a?(Sketchup::Group) || x.is_a?(Sketchup::ComponentInstance) }
        return nil unless e
        b = e.definition.bounds
        nome = (e.get_attribute('pcf', 'nome_fixo') || e.name).to_s
        nome = e.definition.name.to_s if nome.strip.empty?
        dv = e.get_attribute(DA, 'dinabox_dados').to_s
        dv = e.definition.get_attribute(DA, 'dinabox_dados').to_s if dv.empty?
        if dv.start_with?('[M]')
          pt = dv.sub('[M]', '').split('#')
          cod = pt[0].to_s[/M\d+/]
          nome = [cod, pt[1].to_s.strip].reject { |x| x.to_s.empty? }.join(' - ') if pt[1]
        end
        { e: e, b: b, tr: edit_t * e.transformation, nome: nome,
          larg: b.width.to_mm.round(1), prof: b.height.to_mm.round(1), alt: b.depth.to_mm.round(1) }
      end

      def correr
        @dlg_correr.bring_to_front if @dlg_correr && @dlg_correr.visible?
        return correr_enviar if @dlg_correr && @dlg_correr.visible?
        d = UI::HtmlDialog.new(dialog_title: 'PCF · Correr', preferences_key: 'PCF_Correr', width: 860, height: 640,
                               style: UI::HtmlDialog::STYLE_DIALOG, resizable: true)
        d.set_file(File.join(DIR, 'correr.html'))
        d.add_action_callback('pronto') { |_c| correr_enviar }
        d.add_action_callback('salvar') { |_c, js| (correr_salvar_sistema(JSON.parse(js)); correr_enviar(JSON.parse(js)['id'])) rescue aviso("Erro ao salvar: #{$!.message}") }
        d.add_action_callback('restaurar') do |_c, id|
          salvo = (JSON.parse(Sketchup.read_default('PCF_Ferramentas', 'correr_catalogo', '[]').to_s) rescue [])
          Sketchup.write_default('PCF_Ferramentas', 'correr_catalogo', JSON.generate(salvo.reject { |x| x['id'] == id }))
          correr_enviar(id)
        end
        d.add_action_callback('salvar_alu') do |_c, js|
          Sketchup.write_default('PCF_Ferramentas', 'correr_alu', js.to_s)
          correr_enviar
        end
        d.add_action_callback('aplicar') do |_c, js|
          begin
            r = correr_aplicar(JSON.parse(js))
            d.execute_script("feito(#{JSON.generate(r)})")
          rescue StandardError => ex
            puts ex.backtrace.first(6)
            d.execute_script("falhou(#{JSON.generate(ex.message)})")
          end
        end
        d.add_action_callback('fechar') { |_c| d.close }
        d.center
        d.show
        @dlg_correr = d
        @obs_correr ||= begin
          o = Class.new(Sketchup::SelectionObserver) do
            def onSelectionBulkChange(_s)
              PCF::Ferramentas.correr_enviar_alvo
            end

            def onSelectionCleared(_s)
              PCF::Ferramentas.correr_enviar_alvo
            end
          end.new
          model.selection.add_observer(o)
          o
        end
      end

      def correr_enviar(sel_id = nil)
        return unless @dlg_correr && @dlg_correr.visible?
        @dlg_correr.execute_script("iniciar(#{JSON.generate(catalogo_correr)}, #{sel_id.to_json}, #{JSON.generate(alu_opcoes)})")
        correr_enviar_alvo
      end

      def correr_enviar_alvo
        return unless @dlg_correr && @dlg_correr.visible?
        a = correr_alvo
        h = a ? { 'nome' => a[:nome], 'larg' => a[:larg], 'alt' => a[:alt], 'prof' => a[:prof] } : nil
        @dlg_correr.execute_script("alvo(#{JSON.generate(h)})")
      rescue StandardError
        nil
      end

      # barras de trilho para cobrir um comprimento: menor sobra
      def barras_trilho(comp, barras)
        bs = Array(barras).map(&:to_f).select { |x| x > 0 }
        return [] if bs.empty? || comp <= 0
        opcoes = bs.map { |b| n = (comp / b).ceil; [b, n, n * b - comp] }
        b, n, = opcoes.min_by { |_b, n, sobra| [sobra, n] }
        [[b, n]]
      end

      def calc_portas(s, larg, alt, n)
        tr = s['transpasse'].to_f
        w = (larg + tr * (n - 1)) / n.to_f + s['larg_add'].to_f
        h = alt + s['alt_add'].to_f
        [w.round(1), h.round(1)]
      end

      # caixa (grupo) em coordenadas locais do grupo pai: origem p, tamanhos em mm
      def caixa_mm(ents, x, y, z, dx, dy, dz, mat = nil)
        g = ents.add_group
        p0 = [x.mm, y.mm, z.mm]
        f = g.entities.add_face(p0, [(x + dx).mm, y.mm, z.mm], [(x + dx).mm, (y + dy).mm, z.mm], [x.mm, (y + dy).mm, z.mm])
        f.reverse! if f.normal.z < 0
        f.pushpull(dz.mm)
        g.material = mat if mat
        g
      end

      def mat_correr(nome, rgb, alpha = 1.0)
        m = model.materials[nome] || model.materials.add(nome)
        m.color = Sketchup::Color.new(*rgb)
        m.alpha = alpha
        m
      end

      # item de compra: fica no grupo (PCF Label lê 'pcf/compra'); o Dinabox lê o [AR] (item avulso no relatório)
      def marcar_compra(g, itens)
        g.set_attribute('pcf', 'compra', JSON.generate(itens))
      end

      def item_dinabox(ents, cod, desc, qtd, un, comp_mm = 0)
        g = ents.add_group
        g.entities.add_cpoint(ORIGIN)
        g.name = "#{desc} (#{qtd} #{un})"
        dados = "[AR]#{cod}##{desc}##{qtd}##{(comp_mm / 10.0).round(2)}#0#0#0##{un}#CENTIMETERS#0#ferragem[/AR]"
        g.set_attribute(DA, 'dinabox_dados', dados)
        g.set_attribute('pcf', 'compra', JSON.generate([{ 'cod' => cod, 'desc' => desc, 'qtd' => qtd, 'un' => un }]))
        g
      end

      # aplica o sistema no módulo selecionado
      def correr_aplicar(h)
        a = correr_alvo
        raise 'Selecione o módulo (ou a caixa) onde vão as portas.' unless a
        s = catalogo_correr.find { |x| x['id'] == h['id'] } || raise('Sistema não encontrado.')
        s = s.merge(h['sistema'] || {})
        n = [h['n'].to_i, 1].max
        larg = (calc(h['larg'].to_s) || a[:larg]).to_f
        alt = (calc(h['alt'].to_s) || a[:alt]).to_f
        esp = (calc(h['esp'].to_s) || 18.3).to_f
        w, hp = calc_portas(s, larg, alt, n)
        w = calc(h['w'].to_s).to_f if h['w'].to_s.strip != '' && calc(h['w'].to_s)
        hp = calc(h['h'].to_s).to_f if h['h'].to_s.strip != '' && calc(h['h'].to_s)
        aluminio = s['tipo'] == 'aluminio'
        m = model
        m.start_operation("PCF Correr: #{s['nome']}", true)
        begin
          # remove a aplicação anterior neste módulo (refazer = troca, não duplica)
          velhos = m.entities.select { |x| x.respond_to?(:get_attribute) && x.get_attribute('pcf', 'correr_modulo') == a[:e].persistent_id.to_s }
          velhos.each { |x| (x.get_attribute('pcf', 'portas_tamp').to_s.split(',').each { |pid| t = (m.find_entity_by_persistent_id(pid.to_i) rescue nil); t.erase! if t && t.valid? }) }
          m.entities.erase_entities(velhos) unless velhos.empty?
          tr = a[:tr]
          g = m.entities.add_group
          g.transformation = tr
          g.name = "PCF Correr - #{s['nome']} - #{a[:nome]}"
          g.set_attribute('pcf', 'correr_modulo', a[:e].persistent_id.to_s)
          g.set_attribute('pcf', 'correr', JSON.generate({ 'id' => s['id'], 'n' => n, 'larg' => larg, 'alt' => alt, 'w' => w, 'h' => hp, 'esp' => esp }))
          b = a[:b]
          x0 = b.min.x.to_mm; y0 = b.min.y.to_mm; z0 = b.min.z.to_mm
          compras = []
          ao = alu_opcoes
          perfil = ao['perfis'].find { |x| x['nome'] == h['perfil'] } || ao['perfis'].first
          cor = ao['cores'].find { |x| x['nome'] == h['cor'] } || ao['cores'].first
          vidro = ao['vidros'].find { |x| x['nome'] == h['vidro'] } || ao['vidros'].first
          pux = ao['puxadores'].find { |x| x['nome'] == h['puxador'] } || ao['puxadores'].first
          dob = ao['dobradicas'].find { |x| x['nome'] == h['dobradica'] } || ao['dobradicas'].first
          if aluminio && perfil
            s = s.merge('perfil_larg' => perfil['larg'].to_f, 'perfil_prof' => perfil['prof'].to_f,
                        'perfil_nome' => perfil['nome'], 'cor_nome' => cor['nome'], 'vidro_nome' => vidro['nome'],
                        'pux' => pux, 'dob' => (s['id'].to_s.include?('giro') ? dob : nil))
          end
          alu = mat_correr("PCF Alumínio #{cor['nome']}", cor['rgb'])
          vid = mat_correr("PCF Vidro #{vidro['nome']}", vidro['rgb'], (vidro['alpha'] || 0.35).to_f)
          pt = s['prof_trilho'].to_f
          at = s['alt_trilho'].to_f
          # trilhos (na frente do módulo, em cima e embaixo)
          unless s['trilho_sup'].to_s.empty?
            ts = caixa_mm(g.entities, x0, y0 - pt, z0 + alt - at, larg, pt, at, alu); ts.name = "Trilho superior #{s['trilho_sup']}"
            barras_trilho(larg, s['barras']).each do |bl, q|
              compras << { 'cod' => s['trilho_sup'], 'desc' => "Trilho superior #{s['trilho_sup']} (barra #{bl.round} mm)", 'qtd' => q, 'un' => 'barra' }
            end
          end
          unless s['trilho_inf'].to_s.empty?
            ti = caixa_mm(g.entities, x0, y0 - pt, z0, larg, pt, [at, 10].min, alu); ti.name = "Trilho inferior #{s['trilho_inf']}"
            barras_trilho(larg, s['barras']).each do |bl, q|
              compras << { 'cod' => s['trilho_inf'], 'desc' => "Trilho inferior #{s['trilho_inf']} (barra #{bl.round} mm)", 'qtd' => q, 'un' => 'barra' }
            end
          end
          Array(s['kit']).each { |c, d, u, q| compras << { 'cod' => c, 'desc' => "#{d} — #{n} portas", 'qtd' => q.to_f, 'un' => u } }
          Array(s['por_porta']).each { |c, d, u, q| compras << { 'cod' => c, 'desc' => d, 'qtd' => q.to_f * n, 'un' => u } }
          # portas
          portas = []
          tamps = []
          passo = n > 1 ? (larg - w) / (n - 1) : 0
          n.times do |i|
            xi = x0 + i * passo
            yi = y0 - pt - (i.even? ? esp : 2 * esp + 2) # duas linhas de trilho: alternadas
            yi = y0 - esp - 2 if s['id'] == 'alu_giro'
            zi = z0 - s['desce'].to_f
            if aluminio
              pg = porta_aluminio(g.entities, xi, yi, zi, w, hp, s, alu, vid, i)
              pg.name = "Porta alumínio #{i + 1} - #{a[:nome]}"
              portas << pg
            else
              t = porta_mdf(g, xi, yi, zi, w, hp, esp, "Porta correr #{i + 1} - #{a[:nome]}")
              t ? tamps << t : portas << caixa_mm(g.entities, xi, yi, zi, w, esp, hp)
            end
          end
          if aluminio
            pl = s['perfil_larg'].to_f; enc = s['vidro_encaixe'].to_f
            perim = n * 2 * (w + hp) / 1000.0
            vw = w - 2 * pl + 2 * enc; vh = hp - 2 * pl + 2 * enc
            compras << { 'cod' => 'PERFIL-ALU', 'desc' => "#{s['perfil_nome']} — cor #{s['cor_nome']} (quadro das portas)", 'qtd' => perim.round(2), 'un' => 'm' }
            px = s['pux']
            compras << { 'cod' => 'PUXADOR', 'desc' => "#{px['nome']} — cor #{s['cor_nome']}", 'qtd' => n, 'un' => 'un' } if px && px['comp'].to_f != 0
            if s['dob']
              qd = dobr_posicoes(s['dob'], hp).size
              compras.reject! { |c| c['cod'] == 'DOBR-ALU' }
              compras << { 'cod' => 'DOBRADICA', 'desc' => s['dob']['nome'], 'qtd' => qd * n, 'un' => 'un' }
            end
            compras << { 'cod' => 'VIDRO', 'desc' => "Vidro #{s['vidro_nome']} #{s['vidro_esp']} mm — #{n} peça(s) de #{vw.round} × #{vh.round} mm", 'qtd' => (n * vw * vh / 1e6).round(2), 'un' => 'm²' }
          end
          # itens de compra: um por linha (PCF Label) + [AR] para o relatório do Dinabox
          ci = g.entities.add_group; ci.name = 'Compras'
          compras.each { |c| item_dinabox(ci.entities, c['cod'], c['desc'], c['qtd'], c['un']) }
          marcar_compra(g, compras)
          g.set_attribute('pcf', 'portas_tamp', tamps.map { |t| t.persistent_id.to_s }.join(','))
          m.commit_operation
        rescue StandardError
          m.abort_operation
          raise
        end
        arq = nil
        arq = (projeto_aluminio(g, a, s, n, w, hp) rescue "Erro ao gerar o projeto da porta: #{$!.message}") if aluminio && h['projeto'] != false
        mudou
        { 'nome' => a[:nome], 'sistema' => s['nome'], 'n' => n, 'w' => w, 'h' => hp, 'compras' => compras, 'arquivo' => arq, 'mdf_dinabox' => !aluminio && !tamps.empty? }
      end

      # porta de MDF: tamponamento Dinabox (entra no plano de corte do Dinabox), no lugar da porta
      def porta_mdf(g, x, y, z, w, hp, esp, nome)
        molde = molde_tamponamento
        return nil unless molde
        defn, inst_molde = molde
        m = model
        # porta em pé, de frente: ex = largura (x local), ey = altura (z local), ez = espessura (para trás)
        tr = g.transformation
        ex = tr.xaxis; ey = tr.zaxis; ez = ex * ey
        origem = Geom::Point3d.new(x.mm, (y + esp).mm, z.mm).transform(tr)
        t = m.entities.add_instance(defn, Geom::Transformation.axes(origem, ex, ey, ez))
        copiar_atributos(inst_molde, t) if inst_molde
        t.make_unique
        p = t.definition.entities.grep(Sketchup::ComponentInstance).first
        p.make_unique if p
        { 'margem' => '0', 'margem2' => '0', 'margem3' => '0', 'margem_laterais' => '0', 'margem_topos' => '0' }.each do |k, v|
          next if t.get_attribute(DA, k).nil? && t.definition.get_attribute(DA, k).nil?
          t.set_attribute(DA, k, v); t.set_attribute(DA, "_#{k}_formula", v)
        end
        t.set_attribute(DA, '_lenx_formula', (w / 10.0).round(2).to_s)
        t.set_attribute(DA, '_leny_formula', (hp / 10.0).round(2).to_s)
        %w[espessura esp1 espessura1].each { |k| t.set_attribute(DA, k, (esp / 10.0).round(3).to_s); t.set_attribute(DA, "_#{k}_formula", (esp / 10.0).round(3).to_s) }
        redraw(t)
        [t, t.definition].each { |o| nome_fixo(o, nome, nil) } rescue nil
        t.name = nome
        t
      end

      # porta de alumínio: quadro de 4 perfis + vidro
      # posições das dobradiças (do topo para baixo, em mm a partir da base da porta)
      def dobr_posicoes(dob, hp)
        q = dob['qtd'].to_i
        q = hp <= 900 ? 2 : hp <= 1600 ? 3 : hp <= 2200 ? 4 : 5 if q <= 0
        topo = hp - dob['topo'].to_f
        base = dob['base'].to_f
        return [topo] if q == 1
        (0...q).map { |k| (topo - (topo - base) * k / (q - 1).to_f).round(1) }
      end

      # lado da ferragem: porta 1, 3… puxador à direita (dobradiça à esquerda); porta 2, 4… o contrário
      def porta_aluminio(ents, x, y, z, w, hp, s, alu, vid, i = 0)
        pl = s['perfil_larg'].to_f; pp = s['perfil_prof'].to_f; ve = s['vidro_esp'].to_f
        g = ents.add_group
        e = g.entities
        caixa_mm(e, x, y, z, pl, pp, hp, alu).name = 'Perfil esquerdo'
        caixa_mm(e, x + w - pl, y, z, pl, pp, hp, alu).name = 'Perfil direito'
        caixa_mm(e, x + pl, y, z, w - 2 * pl, pp, pl, alu).name = 'Perfil inferior'
        caixa_mm(e, x + pl, y, z + hp - pl, w - 2 * pl, pp, pl, alu).name = 'Perfil superior'
        caixa_mm(e, x + pl, y + (pp - ve) / 2.0, z + pl, w - 2 * pl, ve, hp - 2 * pl, vid).name = 'Vidro'
        info = { 'w' => w, 'h' => hp, 'perfil' => s['perfil_nome'], 'cor' => s['cor_nome'], 'vidro' => s['vidro_nome'] }
        pux_dir = i.even?
        px = s['pux']
        if px && px['comp'].to_f != 0
          comp = px['comp'].to_f < 0 ? hp : px['comp'].to_f
          cz = px['comp'].to_f < 0 ? hp / 2.0 : px['centro'].to_f
          bx = pux_dir ? w - px['borda'].to_f : px['borda'].to_f
          caixa_mm(e, x + bx - 6, y - 25, z + cz - comp / 2.0, 12, 25, comp, alu).name = "Puxador #{px['nome']}"
          info['pux'] = { 'x' => bx, 'z0' => cz - comp / 2.0, 'z1' => cz + comp / 2.0, 'nome' => px['nome'] }
        end
        if s['dob']
          dx = pux_dir ? pl / 2.0 : w - pl / 2.0
          ps = dobr_posicoes(s['dob'], hp)
          ps.each_with_index { |zz, k| caixa_mm(e, x + dx - 8, y + pp, z + zz - 25, 16, 8, 50, alu).name = "Dobradiça #{k + 1}" }
          info['dob'] = { 'x' => dx, 'pos' => ps, 'nome' => s['dob']['nome'] }
        end
        g.set_attribute('pcf', 'porta_alu', JSON.generate(info))
        g
      end

      # projeto da porta de alumínio (separado por módulo), dentro do próprio projeto — seguro, não mexe no resto:
      # as portas são copiadas (lado a lado, cotadas) numa etiqueta própria, longe do projeto (5 m abaixo do chão),
      # e ganham 2 cenas só delas: "Porta alumínio <módulo> - Frontal" e "- Traseira". Nas outras cenas essa etiqueta fica oculta.
      # Também salva um .skp só das portas (cotado) na pasta "Portas de alumínio", ao lado do projeto, para mandar ao serralheiro.
      def projeto_aluminio(g, a, s, n, w, hp)
        m = model
        portas = g.entities.select { |x| x.respond_to?(:get_attribute) && x.get_attribute('pcf', 'porta_alu') }
        raise 'sem portas de alumínio' if portas.empty?
        rotulo = "Porta alumínio #{a[:nome]}"
        tag_nome = "PCF #{rotulo}"
        m.start_operation("PCF: projeto da #{rotulo}", true)
        begin
          # refazer = troca (apaga o projeto anterior deste módulo)
          velhos = m.entities.select { |x| x.respond_to?(:get_attribute) && x.get_attribute('pcf', 'projeto_alu') == a[:e].persistent_id.to_s }
          m.entities.erase_entities(velhos) unless velhos.empty?
          m.pages.to_a.each { |pg| m.pages.erase(pg) if pg.name.start_with?(rotulo + ' - ') }
          tag = m.layers[tag_nome] || m.layers.add(tag_nome)
          tag.visible = true
          gap = 900.0
          novo = m.entities.add_group
          novo.name = "Projeto - #{rotulo}"
          novo.layer = tag
          novo.set_attribute('pcf', 'projeto_alu', a[:e].persistent_id.to_s)
          portas.each_with_index do |p, i|
            c = novo.entities.add_instance(p.definition, Geom::Transformation.new)
            pb = p.bounds
            c.transform!(Geom::Transformation.translation([-pb.min.x + i * (w + gap).mm, -pb.min.y, -pb.min.z]))
          end
          tag_f = m.layers["#{tag_nome} - cotas frontal"] || m.layers.add("#{tag_nome} - cotas frontal")
          tag_t = m.layers["#{tag_nome} - cotas traseira"] || m.layers.add("#{tag_nome} - cotas traseira")
          fer = portas.map { |p| JSON.parse(p.get_attribute('pcf', 'porta_alu').to_s) rescue {} }
          cotar_portas(novo, n, w, hp, gap, s['perfil_larg'].to_f, s, tag_f, tag_t, a[:nome], fer)
          # longe do projeto: 5 m abaixo do chão, alinhado com o módulo
          base = m.bounds
          novo.transform!(Geom::Transformation.translation([base.min.x, base.min.y, base.min.z - 5000.mm - hp.mm]))
          bb = novo.bounds
          c = bb.center
          dist = [bb.width, bb.depth].max * 2 + 3000.mm
          v = m.active_view
          cam0 = v.camera
          cam0 = Sketchup::Camera.new(cam0.eye, cam0.target, cam0.up, cam0.perspective?, cam0.fov)
          paginas = []
          [['Frontal', -1], ['Traseira', 1]].each do |nm, lado|
            cam = Sketchup::Camera.new(c.offset(Geom::Vector3d.new(0, lado, 0), dist), c, Z_AXIS, false)
            cam.height = [bb.depth * 1.08, bb.width * 0.6].max
            v.camera = cam
            pg = m.pages.add("#{rotulo} - #{nm}")
            pg.use_camera = true
            paginas << pg
          end
          # nas cenas da porta: só a etiqueta da porta; nas outras cenas: a etiqueta da porta oculta
          m.pages.each do |pg|
            if paginas.include?(pg)
              cota = pg == paginas[0] ? tag_f : tag_t
              m.layers.each { |l| pg.set_visibility(l, l == tag || l == cota || l == m.layers[0]) rescue nil }
            else
              [tag, tag_f, tag_t].each { |l| pg.set_visibility(l, false) rescue nil }
            end
          end
          v.camera = cam0
          # arquivo separado (só as portas, com as cotas da frente) para mandar ao serralheiro
          arq = nil
          begin
            tag_f.visible = true; tag_t.visible = false
            pasta = m.path.to_s.empty? ? File.join(ENV['USERPROFILE'] || Dir.home, 'Desktop') : File.dirname(m.path)
            pasta = File.join(pasta, 'Portas de alumínio')
            Dir.mkdir(pasta) unless Dir.exist?(pasta)
            arq = File.join(pasta, "#{rotulo}.skp".gsub(/[\\\/:*?"<>|]/, '-'))
            novo.definition.save_as(arq)
          rescue StandardError => ex
            puts "PCF porta alu arquivo: #{ex.message}"
            arq = nil
          end
          tag_f.visible = tag_t.visible = false
          tag.visible = false # na vista normal fica escondido; aparece só nas 2 cenas da porta
          m.commit_operation
        rescue StandardError
          m.abort_operation
          raise
        end
        "Cenas \"#{rotulo} - Frontal\" e \"- Traseira\"" + (arq ? " · arquivo: #{arq}" : '')
      end

      # texto 3D (letra de verdade, cor escura) em pé, virado para quem olha (lado -1 = frente, 1 = verso)
      # al: :centro / :esq (referente ao lado de quem olha)
      def texto3d(ents, str, alt, x, z, y, lado, mat, al = :centro, negrito = false)
        g = ents.add_group
        g.entities.add_3d_text(str, TextAlignLeft, 'Arial', negrito, false, alt.mm, 0.0, 0.0, true, 0.0)
        g.material = mat
        b = g.bounds
        larg = b.width
        dx = al == :centro ? -larg / 2.0 : 0
        t = Geom::Transformation.rotation(ORIGIN, X_AXIS, 90.degrees)
        t = Geom::Transformation.rotation(ORIGIN, Z_AXIS, 180.degrees) * t if lado > 0
        g.transform!(Geom::Transformation.translation([lado > 0 ? -dx : dx, 0, 0]) * t)
        g.transform!(Geom::Transformation.translation([x.mm, y.mm, z.mm]))
        g
      end

      def linha2d(ents, pts, y)
        ents.add_edges(pts.map { |u, v| Geom::Point3d.new(u.mm, y.mm, v.mm) })
      end

      # prancha da porta: moldura, títulos, cotas limpas e quadro com perfil/cor/vidro.
      # 2 grupos: um para a cena Frontal e outro para a Traseira (cada um na sua etiqueta)
      def cotar_portas(grp, n, w, hp, gap, pl, s, tag_f = nil, tag_t = nil, titulo = '', fer = [])
        pp = s['perfil_prof'].to_f
        enc = s['vidro_encaixe'].to_f
        tinta = mat_correr('PCF Cota', [35, 38, 45])
        tot = n * w + (n - 1) * gap
        vw = (w - 2 * pl + 2 * enc).round; vh = (hp - 2 * pl + 2 * enc).round
        { 'Cotas frontal' => [tag_f, -1], 'Cotas traseira' => [tag_t, 1] }.each do |nome, (tag, lado)|
          cg = grp.entities.add_group
          cg.name = nome
          cg.layer = tag if tag
          e = cg.entities
          y = lado < 0 ? -2.0 : pp + 2.0
          # esquerda/direita de quem olha (no verso o X inverte)
          ux = ->(u) { lado < 0 ? u : tot - u }
          dm = lambda do |a, b, v|
            d = e.add_dimension_linear(a.map(&:mm), b.map(&:mm), Geom::Vector3d.new(*v.map(&:mm)))
            d.material = tinta rescue nil
            d.text = "#{mm_txt(Geom::Point3d.new(*a).distance(Geom::Point3d.new(*b)))} mm" rescue nil # 612,5 (sem arredondar)
            d
          end
          n.times do |i|
            x = i * (w + gap)
            # altura total do lado esquerdo de quem olha; se a ferragem estiver desse lado, vai para o outro
            fe0 = fer[i] || {}
            fer_esq = (lado < 0 && fe0['pux'] && fe0['pux']['x'] < w / 2.0) || (lado > 0 && fe0['dob'] && fe0['dob']['x'] > w / 2.0)
            esq = lado < 0 ? x : x + w
            sx = lado < 0 ? -1 : 1
            if fer_esq
              esq = lado < 0 ? x + w : x
              sx = -sx
            end
            dm.([x, y, 0], [x + w, y, 0], [0, 0, -160])                  # largura
            dm.([esq, y, 0], [esq, y, hp], [160 * sx, 0, 0])             # altura
            fe = fer[i] || {}
            if (px = fe['pux']) && lado < 0                                           # puxador (só na frente)
              lx = x + px['x']
              ext = px['x'] > w / 2.0 ? x + w : x
              fora = ext > lx ? 1 : -1
              if px['z1'] - px['z0'] < hp - 1                                       # base → início e comprimento do puxador
                [0, px['z0'], px['z1']].each_cons(2) { |za, zb| dm.([ext, y, za], [ext, y, zb], [fora * 80, 0, 0]) if zb - za > 1 }
              end
              dm.([ext, y, hp], [lx, y, hp], [0, 0, 90])                              # da borda até o centro do puxador
            end
            if (db = fe['dob']) && lado > 0                                           # dobradiças (no verso)
              lx = x + db['x']
              ext = db['x'] < w / 2.0 ? x : x + w
              pts = [hp] + db['pos'] + [0]
              pts.each_cons(2) { |za, zb| dm.([ext, y, za], [ext, y, zb], [(ext < lx ? -1 : 1) * 80, 0, 0]) }
            end
            texto3d(e, format('PORTA %02d', i + 1), 70, x + w / 2.0, hp + 230, y, lado, tinta, :centro, true)
          end
          # moldura da prancha e carimbo
          u0 = -450; u1 = tot + 450; v0 = -1150; v1 = hp + 450
          linha2d(e, [[u0, v0], [u1, v0], [u1, v1], [u0, v1], [u0, v0]], y)
          linha2d(e, [[u0, -420], [u1, -420]], y)
          col = u0 + (u1 - u0) * 0.55
          linha2d(e, [[ux.(col), v0], [ux.(col), -420]], y)
          vista = lado < 0 ? 'VISTA FRONTAL' : 'VISTA TRASEIRA (lado de dentro)'
          texto3d(e, 'PORTAS DE ALUMÍNIO', 75, ux.(u0 + 60), -560, y, lado, tinta, :esq, true)
          texto3d(e, titulo.to_s, 50, ux.(u0 + 60), -680, y, lado, tinta, :esq)
          texto3d(e, vista, 50, ux.(u0 + 60), -800, y, lado, tinta, :esq)
          texto3d(e, "#{n} porta#{n > 1 ? 's' : ''} de #{mm_txt(w)} × #{mm_txt(hp)} mm", 50, ux.(u0 + 60), -920, y, lado, tinta, :esq)
          info = ["Perfil: #{s['perfil_nome']} (#{mm_txt(pl)} × #{mm_txt(pp)} mm)", "Cor do perfil: #{s['cor_nome']}",
                  "Vidro: #{s['vidro_nome']} #{mm_txt(s['vidro_esp'].to_f)} mm", "Medida do vidro: #{vw} × #{vh} mm (#{n} un.)"]
          info << "Puxador: #{s['pux']['nome']}" if s['pux'] && s['pux']['comp'].to_f != 0
          info << "Dobradiças: #{s['dob']['nome']} (#{dobr_posicoes(s['dob'], hp).size} por porta)" if s['dob']
          passo_l = info.size > 4 ? 100 : 120
          info.each_with_index { |t, k| texto3d(e, t, info.size > 4 ? 36 : 42, ux.(col + 50), -520 - k * passo_l, y, lado, tinta, :esq) }
          # no verso o texto "da esquerda" fica à direita do grupo: o ux já espelha a posição
          cg.set_attribute('pcf', 'prancha', true)
        end
      end
    end

    unless file_loaded?(__FILE__)
      ccr = UI::Command.new('Correr') { Ferramentas.correr }
      ccr.tooltip = 'PCF: Biblioteca de correr — trilhos Rometal / Häfele / Dominus e portas de alumínio (com compras e projeto da porta)'
      ccr.status_bar_text = ccr.tooltip
      ccr.small_icon = ccr.large_icon = File.join(DIR, 'icones', 'correr.svg')
      UI.menu('Extensions').add_item(ccr)
      tb = UI.toolbar('PCF')
      tb.add_item(ccr)
      tb.show unless tb.get_last_state == TB_HIDDEN
      file_loaded(__FILE__)
    end
  end
end
