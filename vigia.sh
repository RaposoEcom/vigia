#!/usr/bin/env bash
# Corre dentro do GitHub Actions. Estado em estado.txt:
#   ok
#   baixo <task_id> <epoch desde quando>
set -uo pipefail

ESTADO=$(cat estado.txt 2>/dev/null || echo ok)
agora=$(date +%s)
hora() { TZ=Europe/Lisbon date -d "@$1" '+%d/%m %H:%M'; }

# 3 tentativas, 25 s entre elas, 15 s de limite cada.
vivo=0
for i in 1 2 3; do
  cod=$(curl -s -o /tmp/r -w '%{http_code}' -m 15 "$DASH_URL/healthz" || true)
  if [ "$cod" = 200 ] && grep -q '"ok":true' /tmp/r; then vivo=1; break; fi
  echo "tentativa $i: código $cod"
  [ $i -lt 3 ] && sleep 25
done

echo "site: $([ $vivo = 1 ] && echo responde || echo NÃO responde) · estado anterior: ${ESTADO%% *}"
[ -n "${ENSAIO:-}" ] && { echo "ensaio: não avisa nem grava"; exit 0; }

clickup() { # método caminho json
  curl -s -m 20 -X "$1" "https://api.clickup.com/api/v2/$2" \
    -H "Authorization: $CLICKUP_TOKEN" -H 'Content-Type: application/json' -d "$3"
}

gravar() { # conteúdo mensagem
  echo "$1" > estado.txt
  git config user.name vigia; git config user.email vigia@users.noreply.github.com
  git add estado.txt; git commit -qm "$2"; git push -q
}

if [ $vivo = 0 ] && [ "${ESTADO%% *}" = ok ]; then
  quem=$(jq -nc --arg q "$CLICKUP_QUEM" '$q | split(",") | map(tonumber)')
  corpo=$(jq -nc --arg d "O vigia de fora não conseguiu abrir a dashboard (3 tentativas em ~1 min) às $(hora $agora) de Lisboa.

Pode ser o servidor em baixo, um deploy a meio, o disco cheio ou a Hetzner. Os avisos de saúde de dentro do servidor também param enquanto ele não responder.

Quando voltar, comento aqui com o tempo em baixo." --argjson q "$quem" \
    '{name:"🚨 Dashboard não responde", markdown_description:$d, assignees:$q, priority:1}')
  id=$(clickup POST "list/$CLICKUP_LIST_ID/task" "$corpo" | jq -r '.id // empty')
  [ -z "$id" ] && { echo "✗ não consegui criar a tarefa no ClickUp"; exit 1; }
  echo "✗ tarefa criada"
  gravar "baixo $id $agora" "em baixo"
  exit 0
fi

if [ $vivo = 1 ] && [ "${ESTADO%% *}" = baixo ]; then
  read -r _ id desde <<< "$ESTADO"
  min=$(( (agora - desde) / 60 ))
  texto="✅ A dashboard voltou a responder às $(hora $agora) de Lisboa. Esteve em baixo cerca de $min min (desde $(hora $desde))."
  clickup POST "task/$id/comment" "$(jq -nc --arg t "$texto" '{comment_text:$t, notify_all:true}')" > /dev/null
  echo "✔ voltou, comentado na tarefa"
  gravar ok "voltou"
  exit 0
fi

# O GitHub desliga o agendamento de um repo sem atividade há 60 dias.
ultimo=$(git log -1 --format=%ct)
if [ $(( agora - ultimo )) -gt $(( 25 * 86400 )) ]; then
  git config user.name vigia; git config user.email vigia@users.noreply.github.com
  git commit -q --allow-empty -m "mantém o agendamento ativo" && git push -q && echo "commit de manutenção"
fi

# Só fica vermelho (e o GitHub manda email) se o próprio vigia falhar,
# p.ex. o ClickUp não aceitar a tarefa — serve de aviso de reserva.
exit 0
