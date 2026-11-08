# diag-controle — diagnóstico de controle USB (8BitDo / Xbox) no Android

Script para Termux que descobre **como o Android está enxergando o controle**
(controle de jogo, teclado ou mouse), mostra ao vivo o que cada botão envia e
sugere a correção.

## Instalação (no celular, dentro do Termux)

```bash
pkg install -y git
git clone -b ccr-419b0302-qq6pbz https://github.com/juanscamilo/winlator
cd winlator/tools/controle-diag
termux-setup-storage        # opcional: copia o relatório para Downloads
./diag-controle.sh
```

No menu:

1. **Instalar dependências** (`android-tools`, `python`, `termux-api`).
2. **Conectar ADB** pela *Depuração sem fio* do próprio S23 (sem PC e sem root).
   Necessário porque apps comuns não podem ler `/dev/input`.
3. **Diagnóstico completo** — lê USB, `getevent -lp` e `dumpsys input`, classifica
   o dispositivo e gera `~/diag-controle-*.txt`.
4. **Teste ao vivo** — aperte os botões; cada evento aparece como
   `BOTÃO DE CONTROLE A`, `EIXO Analógico ESQ`, ou `TECLA DE TECLADO KEY_BACK`
   (este último é o que faz o controle "controlar o celular").
5. **Descritor USB via termux-usb** — mostra o modo USB (Xbox One GIP, Xbox 360,
   HID) sem precisar de ADB (requer o app Termux:API).
6. **[root]** instala um keylayout Xbox padrão em `/data/system/devices/keylayout/`.

## Como interpretar

| Resultado | Significado | O que fazer |
|---|---|---|
| `GAMEPAD \| JOYSTICK` + botões A/B/X/Y | Android reconhece como controle | Normal o D-pad navegar no celular. Configure o jogo / Winlator (Input Controls, XInput/DInput) |
| Só `KEYBOARD`/`DPAD` e teclas `KEY_*` | Controle em modo/perfil teclado | Botão de perfil, chave de modo, combinação de modo, restaurar no 8BitDo Ultimate Software |
| `CURSOR` / `REL_X` | Modo mouse | Igual acima |
| Interface `ff/47/d0` com `driver=NENHUM` | Kernel sem driver xpad para esse ID | Firmware do controle, modo BT/2.4G, atualização do One UI ou kernel com root |
