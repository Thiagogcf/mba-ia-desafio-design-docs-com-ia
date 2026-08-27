#!/usr/bin/env bash
#
# validate-docs.sh — porta de qualidade contra alucinação da IA no pacote de design docs.
#
# Verifica, de forma automática, que:
#   1. toda citação "[hh:mm] Nome" nos documentos corresponde a uma fala real da TRANSCRICAO.md;
#   2. todo caminho de arquivo citado como existente realmente existe no repositório;
#   3. o TRACKER.md atende à cobertura mínima exigida (>= 70% TRANSCRICAO, >= 5 linhas CODIGO);
#   4. os arquivos obrigatórios do pacote estão presentes e a pasta de ADRs tem entre 5 e 8 ADRs.
#
# Uso:  bash scripts/validate-docs.sh
# Saída: 0 se tudo passa, 1 se alguma verificação falha.

set -uo pipefail
cd "$(dirname "$0")/.."

PARTICIPANTES='Larissa|Marcos|Bruno|Diego|Sofia'
DOCS=(docs/PRD.md docs/RFC.md docs/FDD.md docs/TRACKER.md docs/adrs/ADR-*.md)
FAIL=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- 1. citações
head_ "1. Citações da transcrição"
grep -oE "^\[[0-9]{2}:[0-9]{2}\] ($PARTICIPANTES):" TRANSCRICAO.md | sed 's/:$//' | sort -u > /tmp/_falas_validas
TOTAL_FALAS=$(wc -l < /tmp/_falas_validas | tr -d ' ')
: > /tmp/_citacoes_ruins
for f in "${DOCS[@]}"; do
  [ -f "$f" ] || continue
  grep -oE "\[[0-9]{2}:[0-9]{2}\] ($PARTICIPANTES)" "$f" | sort -u | while read -r q; do
    grep -qxF "$q" /tmp/_falas_validas || echo "$f -> $q" >> /tmp/_citacoes_ruins
  done
done
USADAS=$(grep -ohE "\[[0-9]{2}:[0-9]{2}\] ($PARTICIPANTES)" "${DOCS[@]}" 2>/dev/null | sort -u | wc -l | tr -d ' ')
if [ -s /tmp/_citacoes_ruins ]; then
  while read -r l; do bad "citação inexistente: $l"; done < /tmp/_citacoes_ruins
else
  ok "$USADAS pares [hh:mm] Nome distintos usados nos docs existem entre os $TOTAL_FALAS pares da TRANSCRICAO.md"
  echo "     (esta checagem prova EXISTÊNCIA do par, não fidelidade do conteúdo citado)"
fi

# ------------------------------------------------------- 2. caminhos de arquivo
head_ "2. Caminhos de arquivo citados"
grep -ohE '(src|tests|prisma|docs|scripts)/[A-Za-z0-9_./-]+\.(ts|md|prisma|sql|json|sh)' "${DOCS[@]}" README.md 2>/dev/null | sort -u > /tmp/_paths
NOVOS='src/worker\.ts|src/modules/webhooks/'   # arquivos propostos pela feature, ainda inexistentes
EXISTENTES=0
: > /tmp/_paths_ruins
while read -r p; do
  echo "$p" | grep -qE "$NOVOS" && continue
  if [ -e "$p" ]; then EXISTENTES=$((EXISTENTES + 1)); else echo "$p" >> /tmp/_paths_ruins; fi
done < /tmp/_paths
for p in package.json docker-compose.yml tsconfig.build.json vitest.config.ts .env.example; do
  grep -qF "$p" "${DOCS[@]}" 2>/dev/null && { [ -e "$p" ] && EXISTENTES=$((EXISTENTES + 1)) || echo "$p" >> /tmp/_paths_ruins; }
done
if [ -s /tmp/_paths_ruins ]; then
  while read -r l; do bad "arquivo citado não existe: $l"; done < /tmp/_paths_ruins
else
  ok "$EXISTENTES caminhos de arquivos existentes conferem"
fi

# ------------------------------------------------- 3b. cobertura dos itens rotulados
cobertura_itens() {
python3 - <<'PYEOF'
import re, pathlib, sys
tracker = pathlib.Path('docs/TRACKER.md').read_text()
padroes = {
 'docs/PRD.md': [r'^\| \*\*(O\d)\*\*', r'^\| (E\d) \|', r'^\| \*\*(F\d)\*\*',
                 r'^\| \*\*(RF-\d+)\*\*', r'^\| \*\*(RNF-\d+)\*\*', r'^\| (D\d) \|',
                 r'^\| \*\*(R\d)\*\*'],
 'docs/RFC.md': [r'^\*\*(Q\d) —'],
 'docs/FDD.md': [r'^\| (OT-\d) \|', r'^\| (RT-\d+) \|', r'^\| `(WEBHOOK_[A-Z_]+)`',
                 r'^### (6\.\d+) '],
}
itens = []
for f, pats in padroes.items():
    txt = pathlib.Path(f).read_text()
    for pat in pats:
        itens += [(f, m) for m in re.findall(pat, txt, re.M)]
itens += [(f'docs/adrs/{q.name}', q.name[:7]) for q in sorted(pathlib.Path('docs/adrs').glob('ADR-*.md'))]

def achou(rot):
    alvo = '§' + rot if re.match(r'^6\.\d', rot) else rot
    return re.search(re.escape(alvo), tracker) is not None

orf = [i for i in itens if not achou(i[1])]
pct = (len(itens) - len(orf)) * 100 // len(itens) if itens else 0
print(f'TOTAL={len(itens)} COBERTOS={len(itens)-len(orf)} PCT={pct}')
for f, r in orf:
    print(f'ORFAO={f}:{r}')
PYEOF
}
head_ "3b. Cobertura dos itens rotulados dos documentos"
if command -v python3 >/dev/null 2>&1; then
  COB=$(cobertura_itens)
  CPCT=$(echo "$COB" | grep '^TOTAL=' | sed 's/.*PCT=//')
  CTOT=$(echo "$COB" | grep '^TOTAL=' | sed 's/TOTAL=\([0-9]*\).*/\1/')
  echo "$COB" | grep '^ORFAO=' | sed 's/^ORFAO=//' | while read -r l; do bad "item rotulado sem linha no tracker: $l"; done
  if [ "${CPCT:-0}" -ge 80 ]; then ok "$CTOT itens rotulados, cobertura ${CPCT}% (exigido >= 80%)"; else bad "cobertura de itens rotulados: ${CPCT}% (exigido >= 80%)"; fi
  echo "$COB" | grep -q '^ORFAO=' && FAIL=1
else
  echo "     (python3 ausente — verificação pulada)"
fi

# ------------------------------------------------------------------ 3. tracker
head_ "3. Cobertura do TRACKER.md"
LINHAS=$(grep -E '^\| (PRD|RFC|FDD|ADR)-' docs/TRACKER.md | grep -cE '\| (TRANSCRICAO|CODIGO) \|')
NTR=$(grep -E '^\| (PRD|RFC|FDD|ADR)-' docs/TRACKER.md | grep -c '| TRANSCRICAO |')
NCO=$(grep -E '^\| (PRD|RFC|FDD|ADR)-' docs/TRACKER.md | grep -c '| CODIGO |')
PCT=$((NTR * 100 / LINHAS))
echo "     linhas: $LINHAS | TRANSCRICAO: $NTR (${PCT}%) | CODIGO: $NCO"
[ "$PCT" -ge 70 ] && ok "TRANSCRICAO >= 70% (${PCT}%)" || bad "TRANSCRICAO abaixo de 70% (${PCT}%)"
[ "$NCO" -ge 5 ]  && ok "CODIGO >= 5 linhas ($NCO)"    || bad "menos de 5 linhas com Fonte=CODIGO ($NCO)"
DER_MARC=$(grep -cE '^\| (PRD|RFC|FDD|ADR)-.*⇢ derivado' docs/TRACKER.md)
DER_NOTAS=$(awk '/^### Itens derivados/{f=1;next} /^### Itens da reunião deliberadamente/{f=0} f' docs/TRACKER.md | grep -cE '^\| (PRD|RFC|FDD|ADR)-')
[ "$DER_MARC" -eq "$DER_NOTAS" ] && ok "itens ⇢ derivado: $DER_MARC marcados = $DER_NOTAS documentados nas notas" \
                                 || bad "itens ⇢ derivado: $DER_MARC marcados mas $DER_NOTAS documentados nas notas"
# todo marcador ⇢ derivado fora do tracker precisa de um ID correspondente na tabela de notas
: > /tmp/_der_orfaos
for f in docs/PRD.md docs/RFC.md docs/FDD.md docs/adrs/ADR-*.md; do
  grep -q '⇢ \*\?derivado' "$f" || continue
  grep -c '⇢ \*\?derivado' "$f" | while read -r c; do echo "$f:$c" >> /tmp/_der_fora; done
done
DER_FORA=$(awk -F: '{soma+=$2} END{print soma+0}' /tmp/_der_fora 2>/dev/null); rm -f /tmp/_der_fora
echo "     ($DER_FORA marcadores ⇢ derivado nos documentos, fora do tracker — cada um deve ter linha no tracker)"
SEM_LOC=$(grep -E '^\| (PRD|RFC|FDD|ADR)-' docs/TRACKER.md | grep -cE '\| (TRANSCRICAO|CODIGO) \| *\|')
[ "$SEM_LOC" -eq 0 ] && ok "nenhuma linha com Localização vazia" || bad "$SEM_LOC linha(s) sem Localização"

# ------------------------------------------------------------- 4. estrutura
head_ "4. Estrutura do pacote"
for f in README.md TRANSCRICAO.md docs/PRD.md docs/RFC.md docs/FDD.md docs/TRACKER.md; do
  [ -f "$f" ] && ok "$f" || bad "$f ausente"
done
NADR=$(ls docs/adrs/ADR-*.md 2>/dev/null | wc -l | tr -d ' ')
[ "$NADR" -ge 5 ] && [ "$NADR" -le 8 ] && ok "docs/adrs/ contém $NADR ADRs (entre 5 e 8)" \
                                       || bad "docs/adrs/ contém $NADR ADRs (esperado entre 5 e 8)"
ADR_FAIL=0
for adr in docs/adrs/ADR-*.md; do
  for s in "## Contexto" "## Decisão" "## Alternativas Consideradas" "## Consequências"; do
    grep -qF "$s" "$adr" || { bad "$(basename "$adr") sem a seção '$s'"; ADR_FAIL=1; }
  done
  grep -qE '^\| \*\*Status\*\*' "$adr" || { bad "$(basename "$adr") sem Status"; ADR_FAIL=1; }
done
[ "$ADR_FAIL" -eq 0 ] && ok "todos os ADRs têm Status, Contexto, Decisão, Alternativas e Consequências"

# ------------------------------------------------- 5. itens fora de escopo
head_ "5. Itens descartados não aparecem como requisito"
if grep -nE '^\| \*\*RF-[0-9]+\*\*' docs/PRD.md | grep -iqE 'e-?mail|dashboard|painel|rate limit'; then
  bad "item explicitamente descartado apareceu como requisito funcional"
else
  ok "nenhum item descartado na reunião virou requisito funcional"
fi

# ------------------------------------------------- 6. links e âncoras internas
head_ "6. Links e âncoras internas entre os documentos"
if command -v python3 >/dev/null 2>&1; then
  LINKOUT=$(python3 - <<'PYEOF'
import re, pathlib, urllib.parse

def slug(h):
    h = re.sub(r'`([^`]*)`', r'\1', h)
    h = re.sub(r'\*\*([^*]*)\*\*', r'\1', h)
    h = re.sub(r'\*([^*]*)\*', r'\1', h)
    return ''.join(c if (c.isalnum() or c in '-_') else '-' if c == ' ' else ''
                   for c in h.strip().lower())

files = ['README.md', 'docs/PRD.md', 'docs/RFC.md', 'docs/FDD.md', 'docs/TRACKER.md'] + \
        sorted(str(p) for p in pathlib.Path('docs/adrs').glob('*.md'))
anchors = {f: {slug(m.group(2)) for m in
               re.finditer(r'^(#{1,6})\s+(.*)$', pathlib.Path(f).read_text(), re.M)}
           for f in files}

bad, checked = [], 0
root = pathlib.Path('.').resolve()
for f in files:
    base = pathlib.Path(f).parent
    for m in re.finditer(r'\]\(([^)\s]+)\)', pathlib.Path(f).read_text()):
        href = m.group(1)
        if href.startswith(('http://', 'https://', 'mailto:')):
            continue
        path, _, frag = href.partition('#')
        frag = urllib.parse.unquote(frag)
        target = (base / path).resolve() if path else pathlib.Path(f).resolve()
        checked += 1
        if not target.exists():
            bad.append(f"{f}: arquivo inexistente -> {href}")
            continue
        rel = str(target.relative_to(root))
        if frag and rel in anchors and frag not in anchors[rel]:
            bad.append(f"{f}: ancora inexistente -> {href}")

print(f"CHECKED={checked}")
for b in bad:
    print(f"BAD={b}")
PYEOF
)
  echo "$LINKOUT" | grep '^BAD=' | sed 's/^BAD=//' | while read -r l; do bad "$l"; done
  echo "$LINKOUT" | grep -q '^BAD=' || ok "$(echo "$LINKOUT" | grep '^CHECKED=' | cut -d= -f2) links internos resolvem (arquivo + âncora)"
  echo "$LINKOUT" | grep -q '^BAD=' && FAIL=1
else
  echo "     (python3 ausente — verificação de links pulada)"
fi

printf '\n'
[ "$FAIL" -eq 0 ] && printf '\033[32m%s\033[0m\n' "VALIDAÇÃO OK" || printf '\033[31m%s\033[0m\n' "VALIDAÇÃO FALHOU"
exit $FAIL
