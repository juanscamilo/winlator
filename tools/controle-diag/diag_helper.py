#!/usr/bin/env python3
"""Helper do diag-controle.sh: analisa dumpsys/getevent, teste ao vivo,
leitura de descritor USB (termux-usb) e geração de keylayout."""
import os
import re
import sys

OK, WARN, ERR, B, R = "\033[32m", "\033[33m", "\033[31m", "\033[1m", "\033[0m"

# Bits de InputDeviceClass (frameworks/native/services/inputflinger EventHub.h)
CLASS_BITS = {
    0x1: "KEYBOARD", 0x2: "ALPHAKEY", 0x4: "TOUCH", 0x8: "CURSOR",
    0x10: "TOUCH_MT", 0x20: "DPAD", 0x40: "GAMEPAD", 0x80: "SWITCH",
    0x100: "JOYSTICK", 0x200: "VIBRATOR", 0x400: "MIC", 0x800: "EXTERNAL_STYLUS",
    0x1000: "ROTARY_ENCODER", 0x2000: "SENSOR", 0x4000: "BATTERY",
    0x8000: "LIGHT", 0x10000: "TOUCHPAD", 0x40000000: "VIRTUAL",
    0x80000000: "EXTERNAL",
}

# Nome Linux -> nome no controle Xbox
XBOX_NAMES = {
    "BTN_SOUTH": "A", "BTN_A": "A", "BTN_GAMEPAD": "A",
    "BTN_EAST": "B", "BTN_B": "B",
    "BTN_NORTH": "X", "BTN_X": "X",
    "BTN_WEST": "Y", "BTN_Y": "Y",
    "BTN_TL": "LB", "BTN_TR": "RB", "BTN_TL2": "LT (digital)", "BTN_TR2": "RT (digital)",
    "BTN_SELECT": "View/Back", "BTN_START": "Menu/Start", "BTN_MODE": "Xbox/Home",
    "BTN_THUMBL": "L3 (clique anal. esq.)", "BTN_THUMBR": "R3 (clique anal. dir.)",
    "BTN_DPAD_UP": "D-pad Cima", "BTN_DPAD_DOWN": "D-pad Baixo",
    "BTN_DPAD_LEFT": "D-pad Esq.", "BTN_DPAD_RIGHT": "D-pad Dir.",
    "KEY_RECORD": "Share", "BTN_C": "C (extra)", "BTN_Z": "Z (extra)",
}
AXIS_NAMES = {
    "ABS_X": "Analógico ESQ (X)", "ABS_Y": "Analógico ESQ (Y)",
    "ABS_RX": "Analógico DIR (X)", "ABS_RY": "Analógico DIR (Y)",
    "ABS_Z": "Gatilho LT (ou anal. dir X em DInput)",
    "ABS_RZ": "Gatilho RT (ou anal. dir Y em DInput)",
    "ABS_GAS": "Gatilho RT", "ABS_BRAKE": "Gatilho LT",
    "ABS_HAT0X": "D-pad (X)", "ABS_HAT0Y": "D-pad (Y)",
}
PHONE_KEYS = {"KEY_UP", "KEY_DOWN", "KEY_LEFT", "KEY_RIGHT", "KEY_ENTER",
              "KEY_BACK", "KEY_ESC", "KEY_HOMEPAGE", "KEY_HOME", "KEY_MENU",
              "KEY_VOLUMEUP", "KEY_VOLUMEDOWN", "KEY_PLAYPAUSE", "KEY_SELECT",
              "KEY_SPACE", "KEY_COMPOSE", "KEY_SEARCH"}

KNOWN_VENDORS = {"2dc8": "8BitDo", "045e": "Microsoft", "0e6f": "PDP",
                 "24c6": "PowerA", "20d6": "PowerA/BDA", "0f0d": "Hori",
                 "057e": "Nintendo", "054c": "Sony"}


def classes_of(text):
    text = text.strip()
    if text.startswith("0x"):
        v = int(text.split()[0], 16)
        return {n for b, n in CLASS_BITS.items() if v & b}
    return {c.strip() for c in text.split("|") if c.strip()}


# ---------------------------------------------------------------- parsers
def parse_dumpsys(txt):
    """Extrai os dispositivos da seção 'Event Hub State' do dumpsys input."""
    devs = []
    m = re.search(r"Event Hub State:(.*?)(?:\nInput Reader State|\Z)", txt, re.S)
    if not m:
        return devs
    cur = None
    for line in m.group(1).splitlines():
        h = re.match(r"^ {4}(-?\d+): (.*)$", line)
        if h:
            cur = {"id": h.group(1), "name": h.group(2).strip(), "raw": [line]}
            devs.append(cur)
            continue
        if cur is None:
            continue
        cur["raw"].append(line)
        kv = re.match(r"^\s+(\w+): ?(.*)$", line)
        if not kv:
            continue
        k, v = kv.group(1), kv.group(2).strip()
        if k == "Classes":
            cur["classes"] = classes_of(v)
        elif k == "Path":
            cur["path"] = v
        elif k == "Identifier":
            for part in v.split(","):
                if "=" in part:
                    a, b = part.strip().split("=", 1)
                    cur[a] = b.replace("0x", "").lower()
        elif k in ("KeyLayoutFile", "KeyCharacterMapFile", "ConfigurationFile",
                   "Location", "ControllerNumber"):
            cur[k] = v
    return devs


def parse_getevent(txt):
    """Parse de 'getevent -lp' -> {path: {name, keys, abs, rel}}"""
    out, cur, sect = {}, None, None
    for line in txt.splitlines():
        m = re.match(r"add device \d+: (\S+)", line)
        if m:
            cur = {"keys": [], "abs": {}, "rel": [], "name": "", "other": []}
            out[m.group(1)] = cur
            sect = None
            continue
        if cur is None:
            continue
        m = re.match(r'\s+name:\s+"(.*)"', line)
        if m:
            cur["name"] = m.group(1)
            continue
        m = re.match(r"\s+(KEY|ABS|REL|SW|LED|FF|MSC|SND)\s*\(\w+\):\s*(.*)", line)
        if m:
            sect, rest = m.group(1), m.group(2)
        elif re.match(r"\s+(input props|events):", line) or not line.startswith("    "):
            if not re.match(r"\s{10,}", line):
                sect = None
            rest = line.strip() if sect else ""
        else:
            rest = line.strip()
        if not sect or not rest:
            continue
        if sect == "KEY":
            cur["keys"] += rest.split()
        elif sect == "REL":
            cur["rel"] += rest.split()
        elif sect == "ABS":
            a = re.match(r"(\S+)\s*:.*min (-?\d+), max (-?\d+)", rest)
            if a:
                cur["abs"][a.group(1)] = (int(a.group(2)), int(a.group(3)))
        else:
            cur["other"].append(sect)
    return out


def parse_usb(txt):
    devs, cur = [], None
    for line in txt.splitlines():
        if line.startswith("DEV "):
            parts = line.split(" ", 3)
            vid, pid = parts[2].split(":")
            cur = {"bus": parts[1], "vid": vid, "pid": pid,
                   "desc": parts[3] if len(parts) > 3 else "", "ifs": []}
            devs.append(cur)
        elif line.startswith("IF ") and cur:
            d = dict(p.split("=", 1) for p in line.split()[2:])
            cur["ifs"].append(d)
    return devs


def iface_kind(cls, sub, proto):
    cls, sub, proto = cls.lower(), sub.lower(), proto.lower()
    if cls == "ff" and sub == "47" and proto == "d0":
        return "Xbox One/Series (protocolo GIP) - precisa do driver xpad"
    if cls == "ff" and sub == "5d" and proto in ("01", "81"):
        return "Xbox 360 (XInput) - precisa do driver xpad"
    if cls == "ff":
        return "vendor-specific (proprietário)"
    if cls == "03":
        return "HID (DInput/Switch/teclado/mouse genérico)"
    if cls == "01":
        return "Áudio (fone no controle)"
    return "classe " + cls


# ---------------------------------------------------------------- analisar
def read(d, f):
    try:
        with open(os.path.join(d, f), errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def usb_input_devices(d):
    devs = parse_dumpsys(read(d, "dumpsys.txt"))
    return [x for x in devs if x.get("bus") == "0003" and x.get("path", "").startswith("/dev/")]


def cmd_listar(d):
    for x in usb_input_devices(d):
        print(f"{x['path']} | {x['name']} | vendor={x.get('vendor')} product={x.get('product')} "
              f"version={x.get('version')} | {' | '.join(sorted(x.get('classes', [])))}")


def cmd_analisar(d):
    print(read(d, "info.txt"))
    dev_ins = parse_dumpsys(read(d, "dumpsys.txt"))
    caps = parse_getevent(read(d, "getevent.txt"))
    usb = parse_usb(read(d, "usb.txt"))
    problemas = []

    print(f"{B}--- 1. Camada USB (o que foi plugado) ---{R}")
    if not usb:
        print(f"{WARN}[!]{R} Não foi possível ler /sys/bus/usb (bloqueio do SELinux é comum). Use a opção 5.")
    for u in usb:
        if not u["ifs"]:
            continue  # hubs/root
        vend = KNOWN_VENDORS.get(u["vid"], "?")
        print(f"  {u['vid']}:{u['pid']} ({vend}) {u['desc']}")
        for i in u["ifs"]:
            kind = iface_kind(i.get("class", ""), i.get("sub", ""), i.get("proto", ""))
            drv = i.get("driver", "NENHUM")
            flag = OK if drv != "NENHUM" else ERR
            print(f"     interface {i.get('class')}/{i.get('sub')}/{i.get('proto')}: {kind}  driver={flag}{drv}{R}")
            if drv == "NENHUM" and i.get("class") == "ff" and i.get("sub") in ("47", "5d"):
                problemas.append(("SEM_DRIVER", u))

    print(f"\n{B}--- 2. Camada de entrada do Android ---{R}")
    usb_in = [x for x in dev_ins if x.get("bus") == "0003"]
    if not usb_in:
        print(f"{ERR}[X]{R} Nenhum dispositivo de entrada USB registrado no Android.")
        problemas.append(("NAO_REGISTRADO", None))
    for x in usb_in:
        cl = x.get("classes", set())
        c = caps.get(x.get("path", ""), {"keys": [], "abs": {}, "rel": []})
        vend = KNOWN_VENDORS.get(x.get("vendor", ""), "?")
        print(f"\n  {B}{x['name']}{R}  ({x.get('path')})")
        print(f"     ID: vendor={x.get('vendor')} ({vend}) product={x.get('product')} version={x.get('version')}")
        print(f"     Classes Android: {' | '.join(sorted(cl)) or '?'}")
        print(f"     KeyLayout: {x.get('KeyLayoutFile', '(nenhum)')}")
        gp_btn = [k for k in c["keys"] if k in XBOX_NAMES]
        ph_keys = [k for k in c["keys"] if k in PHONE_KEYS]
        kb_keys = [k for k in c["keys"] if k.startswith("KEY_") and k not in XBOX_NAMES]
        mouse_btn = [k for k in c["keys"] if k in ("BTN_LEFT", "BTN_RIGHT", "BTN_MIDDLE")]
        print(f"     Botões de gamepad: {len(gp_btn)}  {' '.join(XBOX_NAMES[k] for k in gp_btn)}")
        print(f"     Eixos: {' '.join(c['abs'].keys()) or 'nenhum'}")
        if kb_keys:
            print(f"     Teclas de teclado: {len(kb_keys)} (ex: {' '.join(kb_keys[:8])})")
        if c["rel"] or mouse_btn:
            print(f"     Mouse: {' '.join(c['rel'] + mouse_btn)}")

        is_gp = "GAMEPAD" in cl or "JOYSTICK" in cl
        if is_gp and len(gp_btn) >= 8 and ("ABS_X" in c["abs"] or not c["abs"]):
            print(f"     {OK}=> Reconhecido como CONTROLE DE JOGO de verdade.{R}")
            problemas.append(("GAMEPAD_OK", x))
            if x.get("KeyLayoutFile", "").endswith("Generic.kl"):
                print(f"     {WARN}=> Usa Generic.kl (sem mapeamento específico). Normalmente funciona;"
                      f" se botões estiverem trocados veja a opção 6 (root).{R}")
                problemas.append(("GENERIC_KL", x))
            if "ABS_Z" in c["abs"] and "ABS_RX" not in c["abs"]:
                print(f"     {WARN}=> Layout DInput (anal. dir em Z/RZ). Alguns jogos/Wine leem errado.{R}")
                problemas.append(("DINPUT_LAYOUT", x))
        elif ph_keys and not gp_btn:
            print(f"     {ERR}=> Está enviando TECLAS DE TECLADO/MÍDIA (setas, Enter, Voltar...),"
                  f" não botões de controle!{R}")
            problemas.append(("MODO_TECLADO", x))
        elif c["rel"] or "CURSOR" in cl:
            print(f"     {ERR}=> Está se apresentando como MOUSE.{R}")
            problemas.append(("MODO_MOUSE", x))
        elif kb_keys and not is_gp:
            print(f"     {WARN}=> Dispositivo só de teclas (sem eixos de joystick).{R}")
            problemas.append(("MODO_TECLADO", x))

    print(f"\n{B}--- 3. Diagnóstico e correções ---{R}")
    tipos = {p[0] for p in problemas}
    if "SEM_DRIVER" in tipos:
        print(f"""{ERR}* O controle está no modo Xbox (GIP/XInput) mas o KERNEL do celular não carregou
  driver para este vendor/product.{R} Isso não se corrige sem root/kernel customizado.
  O que tentar:
   - Atualizar o firmware do controle (8BitDo Ultimate Software / Firmware Updater no PC).
   - Se o modelo tiver Bluetooth/2.4G, usar esse modo (o dongle/BT aparece como HID).
   - Se o modelo tiver chave/combinação de modo, trocar para modo D-input/Android.
   - Atualizar o One UI (kernels novos trazem mais IDs no xpad).""")
    if "MODO_TECLADO" in tipos or "MODO_MOUSE" in tipos:
        print(f"""{ERR}* O controle está num modo/perfil de TECLADO ou MOUSE.{R} Por isso ele "controla o celular".
  Correções (a combinação exata depende do modelo - confira o manual do seu 8BitDo):
   - Aperte o botão de PERFIL (Profile/Star, quando existe) até o LED de perfil apagar
     -> volta ao perfil padrão sem remapeamentos.
   - Se houver chave de modo atrás (X / D / S), use X (Xbox/XInput) ou D (DInput/Android).
   - Em vários 8BitDo: desligado, segure START + X (XInput) ou START + B (Android/DInput),
     ou segure X / B enquanto pluga o cabo.
   - No PC, abra o 8BitDo Ultimate Software e verifique se algum botão foi mapeado para
     tecla de teclado/mouse; restaure o padrão e atualize o firmware.
   - Rode o diagnóstico de novo: o objetivo é ver "Classes: ... GAMEPAD | JOYSTICK".""")
    if "NAO_REGISTRADO" in tipos and "SEM_DRIVER" not in tipos:
        print(f"""{WARN}* Nenhum dispositivo de entrada USB.{R} Verifique cabo (precisa ser de DADOS, não só carga),
  adaptador OTG/USB-C, e se o controle está ligado. Teste a opção 5 para ver se o USB é detectado.""")
    if "GAMEPAD_OK" in tipos and not tipos & {"MODO_TECLADO", "MODO_MOUSE", "SEM_DRIVER"}:
        print(f"""{OK}* O Android reconhece como controle de jogo.{R} Observações importantes:
   - É NORMAL o controle navegar pelo celular: no Android o D-pad move o foco, A confirma,
     B volta e o botão Xbox/Home vai para a tela inicial. Isso NÃO significa que está errado.
   - O jogo precisa suportar controle. Jogos Android nativos: procure "Controle/Gamepad"
     nas opções do jogo.
   - No Winlator (jogos Windows): durante o jogo abra o menu lateral > Input Controls,
     selecione um perfil e verifique as opções de controle externo (XInput/DInput);
     em alguns jogos é preciso alternar entre XInput e DInput. Nas configurações do
     container, confirme que os componentes de entrada (xinput/dinput) estão habilitados.
   - Samsung Game Booster: desative "Bloquear durante o jogo > Botões de navegação"
     e similares se o botão Home/Back atrapalhar.
   - Use a opção 4 (teste ao vivo) para confirmar que cada botão chega com o nome certo.""")
    if "DINPUT_LAYOUT" in tipos:
        print(f"""{WARN}* Layout DInput detectado.{R} Se o analógico direito/gatilhos estiverem trocados,
  prefira o modo X-input do controle ou ajuste o mapeamento no Input Controls do Winlator.""")


# ---------------------------------------------------------------- ao vivo
def hex_signed(h):
    v = int(h, 16)
    return v - (1 << 32) if v & 0x80000000 else v


def cmd_vivo(path, caps_file):
    caps = {}
    try:
        caps = parse_getevent(open(caps_file).read()).get(path, {}).get("abs", {})
    except OSError:
        pass
    last = {}
    print(f"{B}Aguardando eventos...{R}")
    for line in sys.stdin:
        parts = line.split()
        if parts and parts[0].endswith(":"):
            parts = parts[1:]
        if len(parts) < 3 or parts[0] == "EV_SYN" or parts[0] == "EV_MSC":
            continue
        typ, code, val = parts[0], parts[1], parts[2]
        if typ == "EV_KEY":
            if val in ("UP", "00000000"):
                continue
            if code in XBOX_NAMES:
                print(f"  {OK}BOTÃO DE CONTROLE{R}  {XBOX_NAMES[code]:<24} ({code})")
            elif code in PHONE_KEYS or code.startswith("KEY_"):
                print(f"  {ERR}TECLA DE TECLADO{R}   {code:<24} <- isso controla o celular, não é gamepad")
            elif code.startswith("BTN_LEFT") or code in ("BTN_RIGHT", "BTN_MIDDLE"):
                print(f"  {ERR}BOTÃO DE MOUSE{R}     {code}")
            else:
                print(f"  {WARN}BOTÃO{R}              {code} (não padrão; precisa mapear no app)")
        elif typ == "EV_ABS":
            try:
                v = hex_signed(val)
            except ValueError:
                continue
            lo, hi = caps.get(code, (-32768, 32767))
            span = max(hi - lo, 1)
            pct = (v - lo) * 200 // span - 100  # -100..100
            if code in ("ABS_Z", "ABS_RZ", "ABS_GAS", "ABS_BRAKE") and lo >= 0:
                pct = (v - lo) * 100 // span  # gatilho 0..100
            prev = last.get(code)
            if prev is not None and abs(pct - prev) < 25 and abs(pct) < 95:
                continue
            last[code] = pct
            print(f"  {OK}EIXO{R}               {AXIS_NAMES.get(code, code):<38} {pct:+4d}%  ({code})")
        elif typ == "EV_REL":
            print(f"  {ERR}MOVIMENTO DE MOUSE{R} {code} {val}")
        sys.stdout.flush()


# ---------------------------------------------------------------- termux-usb
def cmd_usbfd(fd):
    fd = int(fd)
    os.lseek(fd, 0, os.SEEK_SET)
    data = os.read(fd, 8192)
    if len(data) < 18:
        print("Descritor curto demais.")
        return
    vid = data[8] | data[9] << 8
    pid = data[10] | data[11] << 8
    print(f"  VID:PID = {vid:04x}:{pid:04x} ({KNOWN_VENDORS.get(f'{vid:04x}', '?')})  device class={data[4]:02x}")
    i = data[0]
    while i + 2 <= len(data):
        ln, typ = data[i], data[i + 1]
        if ln == 0:
            break
        if typ == 4 and ln >= 9:
            c, s, p = (f"{x:02x}" for x in data[i + 5:i + 8])
            print(f"  interface #{data[i + 2]}: {c}/{s}/{p} -> {iface_kind(c, s, p)}")
        i += ln
    print("  Use esses dados para pesquisar o modo do controle: ff/47/d0 = Xbox One, ff/5d/01 = Xbox 360,"
          " 03 = HID.")


KL = """# Keylayout Xbox padrão (gerado por diag-controle.sh)
key 304   BUTTON_A
key 305   BUTTON_B
key 307   BUTTON_X
key 308   BUTTON_Y
key 310   BUTTON_L1
key 311   BUTTON_R1
key 312   BUTTON_L2
key 313   BUTTON_R2
key 314   BUTTON_SELECT
key 315   BUTTON_START
key 316   BUTTON_MODE
key 317   BUTTON_THUMBL
key 318   BUTTON_THUMBR
key 167   MEDIA_RECORD
axis 0x00 X
axis 0x01 Y
axis 0x03 Z
axis 0x04 RZ
axis 0x02 LTRIGGER
axis 0x05 RTRIGGER
axis 0x10 HAT_X
axis 0x11 HAT_Y
"""


def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__)
        return
    cmd = a[0]
    if cmd == "analisar":
        cmd_analisar(a[1])
    elif cmd == "listar":
        cmd_listar(a[1])
    elif cmd == "vivo":
        try:
            cmd_vivo(a[1], a[2])
        except KeyboardInterrupt:
            pass
    elif cmd == "usbfd":
        cmd_usbfd(a[-1])
    elif cmd == "kl":
        sys.stdout.write(KL)


if __name__ == "__main__":
    main()
