# Gemini Next Step: Realtek USB Audio Identity

## Στόχος

Να βελτιωθεί η αναγνώριση του `USB\VID_0DB0&PID_CD0E&MI_00` χωρίς hardcoded mapping τύπου `0DB0:CD0E = Realtek ALC4080`.

Το σωστό αποτέλεσμα πρέπει να ξεχωρίζει καθαρά:

- Τι αποδεικνύει το `usb.ids`.
- Τι αποδεικνύει το Windows driver/INF evidence.
- Τι αποδεικνύει το motherboard/OEM specification.
- Ποια ταυτότητα είναι local database truth και ποια είναι derived/spec inference.

## Current Finding

Στις 2026-06-04 ελέγχθηκαν τα current upstream/local sources:

- `source\hwdata\usb.ids`
- `data\hwdb\normalized\usb.json`
- `https://raw.githubusercontent.com/vcrhonek/hwdata/master/usb.ids`
- `http://www.linux-usb.org/usb.ids`
- `https://raw.githubusercontent.com/usbids/usbids/master/usb.ids`

Και τα τρία upstream sources έχουν:

```text
0db0  Micro Star International
```

αλλά δεν έχουν product row:

```text
cd0e  USB Audio [Realtek ALC4080]
```

Άρα το sample line που δόθηκε σε chat απάντηση πρέπει να θεωρηθεί unverified/hallucinated μέχρι να βρεθεί πραγματικό upstream source που το περιέχει.

## Local Evidence For This Machine

Το DeviceCheck μπορεί ήδη να συλλέξει τα εξής local facts:

```text
InstanceId : USB\VID_0DB0&PID_CD0E&MI_00\9&9C4D365&0&0000
HardwareId: USB\VID_0DB0&PID_CD0E&REV_0005&MI_00
usb.ids   : VID_0DB0 = Micro Star International
usb.ids   : PID_CD0E = not present
Driver    : oem12.inf / original rtdusbad_msi.inf
Section   : RtkUsbAD.NT
Provider  : Realtek Semiconductor Corp.
Name      : Realtek USB Audio
Extension : oem11.inf / original extrtxusb_msi_rtk.inf
BaseBoard : MAG X870 TOMAHAWK WIFI (MS-7E51)
```

Το installed INF λέει ότι το `USB\VID_0DB0&PID_CD0E&MI_00` είναι Realtek USB Audio device, αλλά δεν περιέχει string `ALC4080`.

## Web/OEM Evidence

Η official MSI specification για `MAG X870 TOMAHAWK WIFI` λέει:

```text
Audio: Realtek ALC4080 Codec
7.1-Channel USB High Performance Audio
```

Source:

```text
https://www.msi.com/Motherboard/MAG-X870-TOMAHAWK-WIFI/Specification
```

Αυτό επιτρέπει derived inference:

```text
This machine's onboard Realtek USB Audio is very likely the Realtek ALC4080 codec from the MSI board spec.
```

Αλλά αυτό δεν είναι `usb.ids` exact product match. Πρέπει να εμφανίζεται με ξεχωριστή source/confidence label.

## Recommended Implementation Path

1. Μην προσθέσεις `0DB0:CD0E -> ALC4080` σε `config\board-model-evidence.json` σαν user-confirmed static mapping.
2. Κράτα το local Hardware ID resolver honest:
   - `Local Match: USB / VENDOR-ONLY / usb.ids`
   - `Coverage: No exact product model in local usb.ids`
   - `Search Hint: USB\VID_0DB0&PID_CD0E&MI_00 Micro Star International 0DB0 CD0E MI_00`
3. Πρόσθεσε μελλοντικά ξεχωριστό `Derived Identity` ή `OEM Spec Identity` layer, όχι raw `usb.ids` layer.
4. Το derived layer να απαιτεί όλα τα παρακάτω:
   - Exact local BaseBoard match: `MAG X870 TOMAHAWK WIFI (MS-7E51)`
   - Installed device match: `USB\VID_0DB0&PID_CD0E&MI_00`
   - Installed INF match: `rtdusbad_msi.inf` / `RtkUsbAD.NT` / `Realtek USB Audio`
   - Official MSI spec or locally cached rendered MSI spec evidence that says `Realtek ALC4080 Codec`
5. Suggested UI wording:

```text
Local Match      : USB / VENDOR-ONLY / usb.ids
Coverage         : No exact product model in local usb.ids
Driver Identity  : Realtek USB Audio / rtdusbad_msi.inf / RtkUsbAD.NT
Spec Inference   : Realtek ALC4080 Codec
Inference Source : MSI MAG X870 TOMAHAWK WIFI official specification
Confidence       : OEM_BOARD_SPEC_INFERENCE / 80-90/100
```

## Guardrail

Do not present `Realtek ALC4080` as an exact USB database match unless a real current `usb.ids` source contains `0db0 cd0e` with that product name.

If a future upstream `usb.ids` update adds `cd0e`, update `source\hwdata\usb.ids`, regenerate `data\hwdb`, and let the normal resolver produce a `PRODUCT` or better confidence match.
