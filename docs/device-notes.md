# Notas do dispositivo — Kindle KT4, firmware 5.18.1.1.1

O que foi medido ou descoberto no aparelho e explica decisões do código.
Tudo foi validado num único Kindle Basic 10ª geração (KT4, Kids Edition),
com jailbreak SpringBreak e SSH pelo Jobman.

## Sistema

| | |
|---|---|
| Kernel | Linux 4.1.15-lab126, armv7l (armhf) |
| CPU / RAM | i.MX6SLL, 1 núcleo (governor `ondemand`, 396–996 MHz) / 512 MB |
| Tela | 600×800, 8 bpp no `/dev/fb0` (stride 608), E Ink 16 tons |
| `/` | ext3 **somente leitura**; o projeto nunca grava nele |
| `/var/local` | ext3 gravável, ~170 MB livres (app WAF e registro) |
| `/mnt/us` | armazenamento do usuário (FUSE `fsp`), ~5,7 GB livres (mapa, dados, receptor) |
| Ferramentas presentes | Lua 5.1.4 com `cjson`, busybox 1.34 (`tcpsvd`, `nc`, `ip`), `iptables` 1.4.15, `curl`, `sqlite3`, `eips`, `lipc-*` |
| Ausentes | Python, Go, compilador; `luasocket`; `fbink` |

## App WAF (Mesquite)

- **Registro:** linha em `/var/local/appreg.db` (`handlerIds` e `properties`), com o comando `/usr/bin/mesquite -l <id> -c file:///var/local/mesquite/<pasta>/`. Abrir com `lipc-set-prop com.lab126.appmgrd start app://<id>`. Os launchers KWebBrew e Mesquito não cobrem a 5.18.1.1.1.
- **Viewport:** a janela fica abaixo da barra do sistema, em 600×680 a partir de y=120. O `innerHeight` às vezes informa 800, e o layout limita a 680 (senão os botões saem da tela).
- **Statusbar:** o **Jobman executa `stop statusbar`**. Sem ele (`com.lab126.chromebar` ausente no log), o Mesquite só repinta as regiões alteradas e a tela parece "agrupada no canto". O script Iniciar faz `start statusbar` antes de abrir o app.
- **Elementos HTML:** usar só `div` com posição em pixels. Elementos HTML5 de seção e SVG inline não foram confiáveis; Canvas também não.
- **Toque:** nenhum evento chegava ao DOM até o app:
  - tratar os callbacks `kindle.appmgr.onload` e `ongo`;
  - enviar `configureChrome` à `com.lab126.chromebar` no `ongo` (mesmo padrão dos WAFs da Amazon);
  - declarar as APIs `gestures` e `viewport` no `config.xml`;
  - remover `enableW3CStd`;
  - abrir com o statusbar ativo.

  Não foi isolado qual dessas mudanças foi a decisiva. O toque chega como `mousedown`, `mouseup` e `click`, e `ontouchstart` não existe.
- **XHR liga o spinner do sistema:** cada XHR dispara o indicador de atividade (`SpinnerHelper` no log), e com polling constante a interface fica "ocupada" e engole toques. Por isso o app **lê o estado por `<script src="location.js?t=...">`**, um arquivo em `/tmp`, por symlink, que o receptor reescreve. Não há XHR no laço principal.
- **Refresh do E Ink:** depois que o mapa se move, o painel pode continuar mostrando o mapa antigo, embora o `/dev/fb0` esteja correto. `eips -s w=600,h=800` faz uma atualização **parcial** da tela inteira a partir do conteúdo desenhado, sem piscar e retornando na hora; com `-f`, faz uma atualização **completa** (~0,7 s, com piscada). O app pede ao receptor por `/api/refresh?mode=partial|full`: parcial a cada passo (no máximo 1/s) e completa a cada ~30 s ou ao mudar o zoom (no máximo a cada 4 s). Os disparos ficam em `/tmp/kindlemap/refresh.log`.
- **Energia:** `lipc-set-prop com.lab126.powerd preventScreenSaver 1` mantém a tela acesa, mas **também desativa o botão de energia**. Por isso é opt-in, ativado pelo arquivo `keep-awake`.

## Rede

- **Firewall:** `iptables` com política INPUT **DROP**. No `wlan0`, só a porta 22 aberta pelo Jobman. O Iniciar adiciona uma regra para a porta 8765, só em memória, e o Parar a remove.
- **`tcpsvd`** exporta `TCPREMOTEADDR="ip:porta"`, e não `TCPREMOTEIP`. O receptor só trata como local o endereço `127.0.0.1`.
- **Rede USB do Jobman:** o Kindle aparece como adaptador RNDIS/Ethernet, não como disco. Kindle em `192.168.15.244`, computador em `192.168.15.201/24`, e o `iptables` libera tudo em `usb0`. É útil quando o SSH por Wi‑Fi cai depois que o Kindle dorme.
- **Wi‑Fi:** desliga quando o Kindle dorme, e o receptor fica inacessível até acordar.

## Desempenho medido

| Operação | Resultado no KT4 |
|---|---|
| `router.lua`, Farol da Barra → Shopping da Bahia, bicicleta (11,7 km) | 3,8 s no total (2,6 s carregando o grafo de 15 MB) |
| Mesma rota, moto/carro (11,1 km) | ~2,8 s |
| Recálculo após sair da rota (2 fixes + roteamento) | ~6 s |
| Busca offline (22 mil itens) | ~0,5 s por consulta |
| Leitura a frio de 30 tiles z17 no `/mnt/us` (FUSE) | 30 ms |
| Resposta do receptor a um POST de posição | ~70 ms |
| Abertura do app (`appmgrd start`) | ~0,3 s |

## Touchscreen

Controlador Cypress `cyttsp5_mt` (`/dev/input/event2`), multitoque protocolo A (sem `ABS_MT_SLOT`), X de 0 a 599 e Y de 0 a 799. O dono deste aparelho relata **falha de toque no lado direito**: os botões ficam afastados da borda direita, e a página `/control` no celular serve de alternativa.

> Rodar `evtest` no `event2` pode capturar o dispositivo com exclusividade e "travar" o toque até o processo terminar. Escrever eventos no `/dev/input/event2` não injeta toques que o sistema aceite.
