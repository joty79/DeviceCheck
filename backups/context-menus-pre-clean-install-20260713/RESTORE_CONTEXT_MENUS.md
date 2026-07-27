# Επαναφορά DeviceCheck Context Menus

Τα πέντε `.reg` αρχεία είναι exports από το live `HKCU` Registry πριν από το clean install του `C:`. Όλα τα commands δείχνουν στο διατηρούμενο repo:

`D:\Users\joty79\scripts\DeviceCheck`

## Επαναφορά μετά το clean install

Από PowerShell 7:

```powershell
Set-Location 'D:\Users\joty79\scripts\DeviceCheck\backups\context-menus-pre-clean-install-20260713'
.\Restore-DeviceCheckContextMenus.ps1
```

Το restore γράφει μόνο στο `HKCU`, επομένως δεν χρειάζεται administrator elevation. Ο helper εισάγει και επαληθεύει και τα πέντε `.reg` αρχεία.

Εναλλακτικά, τα `.reg` μπορούν να εισαχθούν χειροκίνητα με διπλό click, με τη σειρά `01` έως `05`.

## Τι επαναφέρεται

- `DeviceCheck` σε folder background.
- `DeviceCheck` σε folders.
- `DeviceCheck` σε drives.
- Το `.exe` menu `DeviceCheck driver tools`.
- Οι τέσσερις driver-tool επιλογές: `Safe preview + Advisor`, `Trace install + Advisor`, `Safe preview only`, και `Trace install only`.

## Σημαντικό για το extraction toolkit

Τα Registry exports επαναφέρουν τα menus, όχι τα extractor applications που είναι εγκατεστημένα στο `C:`. Μετά το clean install πρέπει να επανεγκατασταθούν τουλάχιστον PowerShell 7, 7-Zip, innoextract, Detect It Easy, lessmsi και Sysinternals Strings πριν από νέο extraction test.
