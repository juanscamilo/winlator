#!/data/data/com.termux/files/usr/bin/bash
# =====================================================================
#  diag-controle.sh - Diagnóstico de controle USB (8BitDo / Xbox) no Android
#  Feito para rodar no Termux (sem root). Usa ADB via "Depuração sem fio"
#  para conseguir ler /dev/input e o "dumpsys input" do sistema.
# =====================================================================
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$DIR/diag_helper.py"
REPORT="$HOME/diag-controle-$(date +%Y%m%d-%H%M%S).txt"

c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_b=$'\e[1m'; c_0=$'\e[0m'
ok()   { echo "${c_ok}[OK]${c_0} $*"; }
warn() { echo "${c_warn}[!]${c_0} $*"; }
err()  { echo "${c_err}[X]${c_0} $*"; }
hdr()  { echo; echo "${c_b}== $* ==${c_0}"; }
pause(){ read -rp "Pressione ENTER para continuar..." _; }

# ---------------------------------------------------------------------
instalar_deps() {
  hdr "Instalando dependências"
  pkg update -y && pkg install -y android-tools python termux-api
  ok "Dependências instaladas."
  echo "Para a opção 5 (leitura USB sem ADB) instale também o app 'Termux:API' (F-Droid/GitHub)."
}

adb_ok() {
  command -v adb >/dev/null || { err "adb não instalado (opção 1)."; return 1; }
  [ "$(adb get-state 2>/dev/null)" = "device" ] || { err "ADB não conectado (opção 2)."; return 1; }
}
sh_adb() { adb shell "$@" 2>/dev/null | tr -d '\r'; }

# ---------------------------------------------------------------------
conectar_adb() {
  hdr "Conectar ADB pela Depuração sem fio (o próprio celular)"
  cat <<TXT
O controle ocupa a porta USB, então usamos ADB por Wi-Fi no próprio S23:
 1. Configurações > Sobre o telefone > Informações do software >
    toque 7x em "Número de compilação" (ativa Opções do desenvolvedor).
 2. Configurações > Opções do desenvolvedor > ative "Depuração sem fio"
    (precisa estar conectado em alguma rede Wi-Fi).
 3. Toque em "Depuração sem fio" > "Parear dispositivo com código".
    DICA: use tela dividida (Termux + Configurações), senão o código some.
TXT
  read -rp "Porta de PAREAMENTO (ex: 37123): " pport
  read -rp "Código de pareamento (6 dígitos): " pcode
  adb pair "127.0.0.1:$pport" "$pcode" || { err "Falha no pareamento."; return; }
  echo "Agora veja a porta mostrada na tela principal de 'Depuração sem fio'"
  echo "(Endereço IP e porta - é DIFERENTE da porta de pareamento)."
  read -rp "Porta de CONEXÃO (ex: 41235): " cport
  adb connect "127.0.0.1:$cport"
  sleep 1
  adb_ok && ok "ADB conectado: $(sh_adb getprop ro.product.model) / Android $(sh_adb getprop ro.build.version.release)"
}

# ---------------------------------------------------------------------
coletar() {
  # Coleta tudo num diretório temporário para o helper analisar
  TMPD="$(mktemp -d)"
  sh_adb dumpsys input > "$TMPD/dumpsys.txt"
  sh_adb getevent -lp > "$TMPD/getevent.txt"
  sh_adb 'for d in /sys/bus/usb/devices/*; do
      [ -f "$d/idVendor" ] || continue
      echo "DEV $(basename $d) $(cat $d/idVendor):$(cat $d/idProduct) $(cat $d/manufacturer 2>/dev/null) | $(cat $d/product 2>/dev/null)"
      for i in $d/$(basename $d):*; do
        [ -f "$i/bInterfaceClass" ] || continue
        drv=$(readlink $i/driver 2>/dev/null); drv=${drv##*/}
        echo "IF  $(basename $i) class=$(cat $i/bInterfaceClass) sub=$(cat $i/bInterfaceSubClass) proto=$(cat $i/bInterfaceProtocol) driver=${drv:-NENHUM}"
      done
    done' > "$TMPD/usb.txt"
  {
    echo "model=$(sh_adb getprop ro.product.model)"
    echo "android=$(sh_adb getprop ro.build.version.release)"
    echo "kernel=$(sh_adb uname -r)"
  } > "$TMPD/info.txt"
}

diagnostico() {
  adb_ok || return
  hdr "Diagnóstico completo"
  echo "Deixe o controle CONECTADO e LIGADO. Coletando dados..."
  coletar
  python "$HELPER" analisar "$TMPD" | tee "$REPORT"
  {
    echo; echo "================ DADOS BRUTOS ================"
    for f in info usb getevent dumpsys; do echo "----- $f -----"; cat "$TMPD/$f.txt"; done
  } >> "$REPORT"
  cp "$TMPD/getevent.txt" "$HOME/.diag-controle-getevent.txt"
  cp "$TMPD/dumpsys.txt"  "$HOME/.diag-controle-dumpsys.txt"
  rm -rf "$TMPD"
  echo; ok "Relatório salvo em: $REPORT"
  [ -d "$HOME/storage/downloads" ] && cp "$REPORT" "$HOME/storage/downloads/" && ok "Cópia em Downloads (para enviar/compartilhar)."
}

# ---------------------------------------------------------------------
escolher_device() {
  # Lista dispositivos de entrada USB e deixa o usuário escolher
  coletar
  python "$HELPER" listar "$TMPD" > "$TMPD/lista.txt"
  if [ ! -s "$TMPD/lista.txt" ]; then
    err "Nenhum dispositivo de entrada USB encontrado. O controle está ligado?"
    rm -rf "$TMPD"; return 1
  fi
  echo "Dispositivos de entrada USB encontrados:"
  nl -w2 -s') ' "$TMPD/lista.txt"
  read -rp "Escolha o número: " n
  DEVPATH="$(sed -n "${n}p" "$TMPD/lista.txt" | cut -d'|' -f1 | tr -d ' ')"
  cp "$TMPD/getevent.txt" "$TMPD.caps"
  rm -rf "$TMPD"
  [ -n "$DEVPATH" ]
}

teste_ao_vivo() {
  adb_ok || return
  hdr "Teste ao vivo dos botões"
  escolher_device || return
  echo "Lendo $DEVPATH. Aperte cada botão, gatilho, analógico e o D-pad."
  echo "Ctrl+C para sair."
  adb shell getevent -l "$DEVPATH" | tr -d '\r' | python "$HELPER" vivo "$DEVPATH" "$TMPD.caps"
  rm -f "$TMPD.caps"
}

# ---------------------------------------------------------------------
usb_sem_adb() {
  hdr "Descritor USB via termux-usb (sem ADB)"
  command -v termux-usb >/dev/null || { err "Instale termux-api (opção 1) e o app Termux:API."; return; }
  mapfile -t devs < <(termux-usb -l | python -c 'import json,sys;[print(d) for d in json.load(sys.stdin)]')
  [ ${#devs[@]} -eq 0 ] && { err "Nenhum dispositivo USB visto pelo Android."; return; }
  for d in "${devs[@]}"; do
    echo "Dispositivo: $d  (aceite a permissão USB que aparecer)"
    termux-usb -r -e "python $HELPER usbfd" "$d"
  done
}

# ---------------------------------------------------------------------
instalar_kl_root() {
  hdr "[ROOT] Instalar keylayout de controle Xbox padrão"
  command -v su >/dev/null || { err "Sem root (su). Esta correção exige root."; return; }
  adb_ok || return
  coletar
  read -r v p ver < <(python "$HELPER" detectar "$TMPD")
  rm -rf "$TMPD"
  [ -z "${v:-}" ] && { err "Nenhum controle detectado. Ligue o controle e tente de novo."; return; }
  echo "Controle detectado: vendor=$v product=$p version=$ver"
  f="Vendor_${v}_Product_${p}_Version_${ver}.kl"
  python "$HELPER" kl > "$HOME/$f"
  su -c "mkdir -p /data/system/devices/keylayout && cp '$HOME/$f' /data/system/devices/keylayout/ && chmod 644 /data/system/devices/keylayout/$f && restorecon -R /data/system/devices" \
    && ok "Instalado /data/system/devices/keylayout/$f - desconecte e reconecte o controle."
}

# ---------------------------------------------------------------------
PADFIX_REMOTE=/data/local/tmp/padfix

corrigir_sem_root() {
  hdr "Corrigir SEM ROOT (remapeador padfix)"
  adb_ok || return
  coletar
  read -r v p ver < <(python "$HELPER" detectar "$TMPD")
  rm -rf "$TMPD"
  [ -z "${v:-}" ] && { err "Nenhum controle detectado. Ligue o controle e tente de novo."; return; }
  echo "Controle detectado: $v:$p"

  # Escolhe uma identidade Xbox para a qual ESTE celular tem keylayout correto
  clone=""
  for cand in 045e:02ea 045e:02dd 045e:02d1 045e:0b12 045e:028e; do
    f="Vendor_${cand%:*}_Product_${cand#*:}.kl"
    if sh_adb "cat /system/usr/keylayout/$f /vendor/usr/keylayout/$f /product/usr/keylayout/$f /odm/usr/keylayout/$f 2>/dev/null" | grep -q "LTRIGGER"; then
      clone="$cand"; break
    fi
  done
  [ -z "$clone" ] && { err "Nenhum keylayout de Xbox encontrado no sistema; não dá para usar este método."; return; }
  ok "Identidade do clone: $clone (keylayout Xbox presente no sistema)"

  if ! command -v clang >/dev/null && ! command -v cc >/dev/null; then
    echo "Instalando compilador (clang)..."; pkg install -y clang || { err "Falha ao instalar clang."; return; }
  fi
  if [ ! -x "$HOME/padfix" ] || [ "$DIR/padfix.c" -nt "$HOME/padfix" ]; then
    cc -O2 -o "$HOME/padfix" "$DIR/padfix.c" || { err "Falha ao compilar padfix.c"; return; }
  fi
  adb shell "pkill -x padfix" >/dev/null 2>&1
  adb push "$HOME/padfix" "$PADFIX_REMOTE" >/dev/null || { err "Falha ao enviar o binário."; return; }
  adb shell "chmod 755 $PADFIX_REMOTE; nohup $PADFIX_REMOTE $v $p ${clone%:*} ${clone#*:} >$PADFIX_REMOTE.log 2>&1 &"
  sleep 2
  log="$(sh_adb cat $PADFIX_REMOTE.log)"
  echo "$log"
  if echo "$log" | grep -q "ATIVO"; then
    kl="$(sh_adb dumpsys input | grep -A14 'Xbox Controller (padfix)' | grep -m1 KeyLayoutFile)"
    ok "Remapeador ativo. $kl"
    echo "Teste agora num jogo: analógico direito e gatilhos devem estar corretos."
    echo "Ele continua rodando em segundo plano (pode fechar o Termux). Se desconectar o"
    echo "controle ele espera voltar. Depois de REINICIAR o celular, rode esta opção de novo."
    echo "Limitação: sem vibração (rumble)."
  else
    err "O remapeador não iniciou. Envie a mensagem acima para análise."
  fi
}

parar_padfix() {
  adb_ok || return
  adb shell "pkill -x padfix" && ok "Remapeador parado; o controle voltou ao estado original." || warn "Não estava rodando."
}

# ---------------------------------------------------------------------
# Modo automático (usado pelo atalho da tela inicial): ./diag-controle.sh --ligar
avisar() {
  echo "$*"
  command -v termux-toast >/dev/null && termux-toast -g middle "$*" >/dev/null 2>&1
}

auto_conectar() {
  [ "$(adb get-state 2>/dev/null)" = "device" ] && return 0
  adb connect 127.0.0.1:5555 >/dev/null 2>&1
  [ "$(adb get-state 2>/dev/null)" = "device" ] && return 0
  # A porta da Depuração sem fio muda a cada ativação: procura portas abertas
  for port in $(python - <<'PY'
import socket
for p in range(30000, 50000):
    s = socket.socket(); s.settimeout(0.05)
    if s.connect_ex(("127.0.0.1", p)) == 0: print(p)
    s.close()
PY
  ); do
    adb connect "127.0.0.1:$port" >/dev/null 2>&1
    sleep 1
    [ "$(adb get-state 2>/dev/null)" = "device" ] && return 0
    adb disconnect "127.0.0.1:$port" >/dev/null 2>&1
  done
  return 1
}

modo_ligar() {
  if ! auto_conectar; then
    avisar "Controle: ative a 'Depuração sem fio' (Wi-Fi ligado) e toque de novo."
    exit 1
  fi
  if sh_adb "cat $PADFIX_REMOTE.log" | tail -1 | grep -q "ATIVO\|aguardando" && sh_adb "pgrep -x padfix" | grep -q .; then
    avisar "Controle: remapeador já está ligado."
    exit 0
  fi
  if corrigir_sem_root | tee "$HOME/.padfix-ultimo.log" | grep -q "Remapeador ativo"; then
    avisar "Controle Xbox: remapeador LIGADO."
  else
    avisar "Controle: falhou. Veja ~/.padfix-ultimo.log (controle está conectado?)"
    exit 1
  fi
}

instalar_atalho() {
  hdr "Atalho na tela inicial (Termux:Widget)"
  mkdir -p "$HOME/.shortcuts/tasks"
  for n in "Controle Xbox ON:--ligar" "Controle Xbox OFF:--desligar"; do
    f="$HOME/.shortcuts/tasks/${n%%:*}.sh"
    printf '#!/data/data/com.termux/files/usr/bin/bash\nexec "%s/diag-controle.sh" %s\n' "$DIR" "${n##*:}" > "$f"
    chmod 700 "$f"
  done
  ok "Atalhos criados em ~/.shortcuts/tasks/"
  cat <<TXT
Agora:
 1. Instale o app "Termux:Widget" (mesma fonte do seu Termux: F-Droid ou GitHub).
 2. Na tela inicial: segure num espaço vazio > Widgets > Termux:Widget > arraste.
 3. Toque em "Controle Xbox ON" - roda em segundo plano, sem abrir o Termux.
    (Com o app Termux:API instalado aparece um aviso na tela com o resultado.)
 4. Opcional: Opções do desenvolvedor > "Blocos de configurações rápidas do
    desenvolvedor" > ative "Depuração sem fio" para ligá-la pelo painel rápido.
TXT
}

case "${1:-}" in
  --ligar) modo_ligar; exit 0 ;;
  --desligar) auto_conectar && adb shell "pkill -x padfix"; avisar "Controle: remapeador desligado."; exit 0 ;;
esac

# ---------------------------------------------------------------------
while true; do
  hdr "Diagnóstico de controle (8BitDo / Xbox) - S23"
  cat <<M
 1) Instalar dependências (adb, python, termux-api)
 2) Conectar ADB (Depuração sem fio)
 3) Diagnóstico completo + relatório
 4) Teste ao vivo dos botões (mostra o que o Android recebe)
 5) Ler descritor USB direto (termux-usb, sem ADB)
 6) [ROOT] Instalar mapeamento (keylayout) Xbox padrão
 7) CORRIGIR SEM ROOT: ligar remapeador (eixos/gatilhos de Xbox)
 8) Desligar remapeador
 9) Criar atalho na tela inicial (ligar com 1 toque, sem abrir o Termux)
 0) Sair
M
  read -rp "> " op
  case "$op" in
    1) instalar_deps ;; 2) conectar_adb ;; 3) diagnostico ;;
    4) teste_ao_vivo ;; 5) usb_sem_adb ;; 6) instalar_kl_root ;;
    7) corrigir_sem_root ;; 8) parar_padfix ;; 9) instalar_atalho ;;
    0) exit 0 ;; *) warn "Opção inválida" ;;
  esac
  pause
done
