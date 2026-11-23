# Protocolo de posição telefone → Kindle

## Premissas

- Wi‑Fi local é o transporte inicial; não requer internet móvel durante o percurso, desde que o telefone e o Kindle estejam na mesma rede/hotspot.
- O telefone obtém posição via Android Location Services ou iOS Core Location.
- BLE fica como alternativa posterior: requer prova de compatibilidade do stack Bluetooth do KT4 e execução em segundo plano nos dois sistemas.
- Enviar posição somente quando houver deslocamento relevante ou a cada intervalo configurável (inicialmente 5–10 s), para reduzir rádio, bateria e refresh do E Ink.
- Os dados de localização devem ficar na rede local; não enviar coordenadas para serviços externos.

## Mensagem v1

`POST /api/location` com JSON UTF‑8:

```json
{
  "version": 1,
  "source": "android",
  "timestamp_utc": "2026-11-22T20:00:00Z",
  "latitude": -12.9714,
  "longitude": -38.5014,
  "accuracy_m": 8.0,
  "speed_mps": 4.2,
  "course_deg": 87.0
}
```

`source` pode ser `android` ou `ios`. `speed_mps` e `course_deg` podem ser `null` se o sistema não tiver valor confiável. O Kindle deve mostrar posição desatualizada após 15 s sem mensagem e desconectada após 60 s.

## Receptor no Kindle (implementado, v0.2.0)

`kindle-map/receiver/gpsd.lua`, executado por `tcpsvd` (busybox) + Lua 5.1/cjson já presentes no KT4, porta **8765**. Estado só em RAM (`/tmp/kindlemap`).

| Rota | Uso | Token |
|---|---|---|
| `POST /api/location` | Mensagem v1 (JSON acima) | sim |
| `POST /owntracks` | OwnTracks em modo HTTP (`_type:"location"`, `lat`, `lon`, `vel` km/h, `cog`, `acc`, `tst`) | sim |
| `GET /api/update?lat=&lon=&spd=&dir=&acc=` | GPSLogger "Custom URL" (spd em m/s) | sim |
| `GET /api/location` | Último fix | só para acesso remoto |
| `GET /api/status` | Versão, IP, se há fix | não (token só é exibido para 127.0.0.1) |
| `GET /control?token=` | Página de controle do mapa para o navegador do celular (+, −, DETALHE, GERAL, SEGUIR) | sim |
| `GET /api/cmd?c=in\|out\|detail\|overview\|follow` | Comando de mapa; o app aplica em até 2 s via `location.js` | sim |
| `GET /nav?token=` | Página de rota no celular: busca, perfil bicicleta/moto‑carro, traçar, cancelar, recalcular, zoom | sim |
| `GET /api/search?q=` | Busca offline (ruas por bairro, bairros, lugares) em `data/search.json`; 12 melhores, priorizando perto do último fix | sim (remoto) |
| `POST /api/route` `{lat, lon, label, profile}` | Calcula rota offline no Kindle (`router.lua`, ~3–4 s), origem = último fix (ou `from_lat/from_lon`). `202` aceito, `409` sem fix ou já calculando | sim (remoto) |
| `GET /api/route` | Rota atual (`pts` em graus×1e6, `cum` m, `maneuvers`) | sim (remoto) |
| `POST /api/route/cancel` | Encerra a navegação | sim (remoto) |
| `GET /api/nav` | Estado: `none/calculating/rerouting/active/arrived/error`, próxima manobra, restante, ETA | sim (remoto) |
| `GET /` | Página de ajuda | não |

Respostas: `200` com corpo `[]` quando aceito (formato que o OwnTracks espera); `400` em payload inválido/fora de faixa; `401` sem token; `413` acima de 16 KiB. O token pode ir como `?token=`, cabeçalho `X-Token`, `Authorization: Bearer` ou como senha no Basic auth (OwnTracks).

O token (6 hex) é gerado na primeira execução em `/mnt/us/kindlemap/token`, aparece na barra inferior do app e só é revelado a requisições de `127.0.0.1`. Para trocar, apague o arquivo e reinicie o receptor. Não usar a senha root do SSH como token.

A idade do fix é calculada pelo horário de **recebimento** no Kindle (mesmo relógio do app), não pelo timestamp do telefone, para não depender de sincronia de relógio.

## Navegação (v0.4)

- Grafo: `tools/build_graph.py` → `/mnt/us/kindlemap/data/graph.json` (84 mil nós, 109 mil trechos). Perfis: bicicleta (respeita mão única salvo `oneway:bicycle=no`/contrafluxo, evita `motorway`/`trunk`/escadas, prefere ciclovia) e moto/carro (respeita mão única, só vias motorizadas).
- Progresso a cada fix (`nav.lua`): projeção no trajeto, próxima manobra, restante e ETA vão em `location.js` (`snap.nav`). Fora da rota (>35 m bicicleta, >50 m carro) em 2 fixes seguidos → recálculo automático a partir da posição atual. Chegada a <25 m.
- A geometria vai ao app por `route.js` (symlink para `/tmp/kindlemap/route.js`), carregado só quando `route_id` muda.
