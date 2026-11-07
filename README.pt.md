# Viñeta para KOReader

[English](README.md) · [Español](README.es.md) · **Português** · [Français](README.fr.md) · [Deutsch](README.de.md)

> **Baseado na [Viñeta](https://play.google.com/store/apps/details?id=com.dsp.vineta), a app Android para ler banda desenhada vinheta a vinheta.**
> Este plugin leva aos leitores e-ink com KOReader o mesmo detetor de vinhetas da app.

<a href="https://play.google.com/store/apps/details?id=com.dsp.vineta"><img alt="Disponível no Google Play" src="https://play.google.com/intl/pt/badges/static/images/badges/pt_badge_web_generic.png" height="64"></a>

Plugin do [KOReader](https://koreader.rocks) para ler banda desenhada **vinheta a vinheta** em leitores e-ink. É o próprio leitor que encontra as vinhetas com o detetor da Viñeta, enquanto lê: não é preciso preparar nada no computador e o ficheiro do livro não é alterado.

> **Nota:** por agora, os menus do plugin estão em espanhol. Abaixo, as opções aparecem tal como surgem no ecrã, seguidas do seu significado.

## Instalação

1. Instale o [KOReader](https://github.com/koreader/koreader/releases) no seu leitor.
2. Copie a pasta `vineta.koplugin` para dentro da pasta `plugins` do KOReader. Por exemplo:
   - PocketBook: `applications/koreader/plugins/`
   - Kobo: `.adds/koreader/plugins/`
   - Kindle: `koreader/plugins/`
3. Reinicie o KOReader e abra um livro CBZ ou CBR a partir do seu explorador de ficheiros.

## Leitura

O livro abre automaticamente no modo vinheta a vinheta. Cada página é mostrada primeiro inteira e depois vinheta a vinheta. As vinhetas grandes, que quase não ficariam maiores no ecrã, são mostradas em duas metades: primeiro a da esquerda e depois a da direita. Se o livro tiver um `ComicInfo.xml` que indique que é manga, é lido da direita para a esquerda sem configurar nada. Um pequeno número no canto («3/7») indica em que passo da página se encontra.

Cada página é analisada em segundo plano na primeira vez que é lida, e o resultado fica guardado: quando voltar ao livro, já não tem de esperar.

O menu do KOReader → separador de navegação → «Viñeta a viñeta» (vinheta a vinheta) tem o interruptor **«Activado»** (ativado) para ligar ou desligar o plugin. A partir daí também pode entrar no modo com um PDF, ou se tiver saído dele.

| | |
|---|---|
| Toque à direita / botão de avançar | Vinheta seguinte |
| Toque à esquerda / botão de recuar | Vinheta anterior |
| Pressão longa | Página inteira ↔ vinheta |
| Beliscar (juntar dois dedos) / deslizar para cima ou para baixo | Desativar o zoom: páginas inteiras, passa-se de página em página |
| Afastar dois dedos / deslizar para cima ou para baixo | Voltar a ativar o zoom: vinheta a vinheta a partir da primeira |
| Toque no centro | Menu (sentido manga, zoom, página inteira, sair) |

Sem zoom, o canto mostra «sin zoom» (sem zoom). Cada livro lembra-se se o deixou com o zoom ativado ou desativado.

No menu «Viñeta a viñeta» do KOReader também pode:

- começar cada página inteira ou ir diretamente para a primeira vinheta;
- dividir em duas metades as vinhetas que não ganham 10, 20, 30 ou 50 % de largura, ou nenhuma;
- fazer zoom aos balões de fala das vinhetas muito largas ou muito altas;
- ver primeiro cada metade das páginas duplas;
- aumentar o contraste (a banda desenhada a cores fica desbotada em 16 tons de cinzento);
- ocultar o número do passo;
- escolher com que frequência o ecrã é totalmente atualizado, incluindo «ao mudar de página»;
- analisar 2 páginas à frente, 5 ou o livro inteiro, e escolher a análise rápida (menos precisa);
- voltar a procurar as vinhetas de um livro.

Em «Toques y gestos» (toques e gestos) pode atribuir a um gesto a opção «Activar o desactivar Viñeta a viñeta» (ativar ou desativar vinheta a vinheta).

Como foi feito o detetor em Lua (em espanhol): [docs/detector-lua.md](docs/detector-lua.md).

## Licença

[AGPL-3.0](LICENSE), a mesma do KOReader. Pode usar, modificar e redistribuir o plugin desde que partilhe o código com a mesma licença.

Além disso, ao abrigo da secção 7(b) da AGPL, quem redistribuir o plugin ou uma obra derivada (incluindo apenas o detetor de vinhetas) deve manter a atribuição ao seu autor. Os detalhes estão em [NOTICE](NOTICE).
