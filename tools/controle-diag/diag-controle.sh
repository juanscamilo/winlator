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
while true; do
  hdr "Diagnóstico de controle (8BitDo / Xbox) - S23"
  cat <<M
 1) Instalar dependências (adb, python, termux-api)
 2) Conectar ADB (Depuração sem fio)
 3) Diagnóstico completo + relatório
 4) Teste ao vivo dos botões (mostra o que o Android recebe)
 5) Ler descritor USB direto (termux-usb, sem ADB)
 6) [ROOT] Instalar mapeamento (keylayout) Xbox padrão
 0) Sair
M
  read -rp "> " op
  case "$op" in
    1) instalar_deps ;; 2) conectar_adb ;; 3) diagnostico ;;
    4) teste_ao_vivo ;; 5) usb_sem_adb ;; 6) instalar_kl_root ;;
    0) exit 0 ;; *) warn "Opção inválida" ;;
  esac
  pause
done
