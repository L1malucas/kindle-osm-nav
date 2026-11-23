# Etapa 1 — medições da interface original do KT4

Antes do app de mapa, o projeto tentou medir a experiência do Kindle original:
navegação entre telas, toque e abertura de livros. A etapa ficou **pausada**. Os
números abaixo são preliminares e servem de referência, não de conclusão.

Regras seguidas: rootfs em somente leitura durante a coleta, nenhum serviço
Amazon removido ou desativado, nenhum conteúdo de livro copiado para fora do
aparelho.

## Linha de base manual (cronômetro, 3 repetições)

| Fluxo | Livro Amazon | PDF | MOBI |
|---|---|---|---|
| Home → abrir livro → virar 3 páginas → barra de tarefas → Home | ~23 s | ~23 s | ~23 s |
| Home → primeira página legível | ~14 s | ~14 s | ~14 s |

A abertura do livro foi apontada como a parte mais lenta. Os ~9 s restantes do
fluxo completo (viradas, barra e retorno) não foram cronometrados por subetapa,
e os tamanhos dos arquivos não foram registrados.

## Sistema durante a coleta

- **CPU:** amostras de `top` entre 39% e 76% ociosa, com load average de ~0,7–0,8. As medições incluíam o próprio SSH e os comandos, então não provam um consumidor persistente.
- **Memória:** ~10 MB livres, mas com ~126 MB de cache e ~130 MB de swap livre. Os maiores residentes foram `cvm` (~114 MB) e `KPPMainApp` (~66 MB), ambos do framework.
- **Governor:** `ondemand`, 396 MHz em repouso, faixa de 396–996 MHz; `performance` está disponível. A comparação A/B não foi feita.
- **Espaço:** `/` ~44 MB livres, `/var/local` ~172 MB, `/mnt/us` ~5,8 GB. O `/opt/amazon` ocupa ~43 MB, o que não justifica remover componentes para ganhar espaço.
- **Logs:** `/var/log/messages` e `/var/local/log/messages_*.gz` não têm uma trilha estruturada de tempos de interface; `readingstreams.db` é só uma fila de mensagens.

## Touchscreen

O usuário relata **falha de toque no lado direito**.

- **Controlador:** Cypress `cyttsp5_mt` em `/dev/input/event2` (X 0–599, Y 0–799), IRQ 128 (GPIO 3, borda), endereço `1-0024`.
- **Contador de interrupções**, 10 toques por região: +118 no centro, +100 à esquerda e +53 à direita. Há atividade nas três regiões, mas o contador não equivale a toques processados.
- **`evtest`:** listou as capacidades, mas não mostrou eventos, provavelmente porque o Xorg mantém o dispositivo. Rodá-lo pode capturar o toque com exclusividade.
- **Boot:** o driver falhou primeiro ao ler o descritor HID (`rc=-5`) e depois reinicializou. É um indício, não um diagnóstico.

O mapa de zonas mortas não foi concluído. O app de mapa contorna o problema
mantendo os botões longe da borda direita e oferecendo os controles pelo celular.

## Próximos passos (se a etapa for retomada)

1. Mapa de pontos de toque em grade, antes e depois de suspender o aparelho.
2. Cinco medições por cenário, com mediana e variação, por formato e tamanho de arquivo.
3. Só depois disso, testar uma mudança reversível por vez (governor, índices, conversão de PDF) e documentar como reverter.
