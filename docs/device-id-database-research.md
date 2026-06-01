# 🔵 Έρευνα & Σχεδιασμός Τοπικών Βάσεων Δεδομένων Device ID (31 Μαΐου 2026)

Αυτό το έγγραφο αναλύει πώς μπορούμε να ενσωματώσουμε τοπικές και online βάσεις δεδομένων (Device ID Databases) στο `DeviceCheck` για να πετύχουμε 100% ντετερμινιστική αναγνώριση των συσκευών (PCI, USB, MONITOR/DISPLAY) χωρίς να βασιζόμαστε αποκλειστικά στο AI Overview της Google.

---

## 🔵 1. Βάσεις Δεδομένων PCI & USB (pci.ids & usb.ids)

### 🔸 PCI ID Repository (pci-ids.ucw.cz)
- **Αρχείο:** `pci.ids`
- **Δομή:** Ένα ελαφρύ αρχείο κειμένου (~1.5 MB) που ενημερώνεται καθημερινά και περιέχει πλήρεις λίστες για PCI Vendors, Devices, Subsystems, και Classes.
- **Παράδειγμα Mapping:**
  ```text
  10de  NVIDIA Corporation
      2803  AD104 [GeForce RTX 4070 Ti]
          1462 5174  GeForce RTX 4070 Ti Gaming X Slim
  ```
- **Πρόταση Ενσωμάτωσης:** Το `DeviceCheck` μπορεί να κατεβάζει αυτόματα το `pci.ids` στο `%LOCALAPPDATA%\DeviceCheck\databases\pci.ids` και να κάνει parse τα IDs τοπικά.

### 🔸 USB ID Repository (linux-usb.org)
- **Αρχείο:** `usb.ids`
- **Δομή:** Παρόμοιο text-based αρχείο για USB Vendors, Devices, και Interfaces.
- **Πρόταση Ενσωμάτωσης:** Κατέβασμα και τοπικό parsing για άμεση αναγνώριση οποιασδήποτε USB συσκευής χωρίς API calls.

---

## 🔵 2. Βάσεις Δεδομένων Monitor EDID & PNP IDs (DISPLAY\GSM5BD3)

🔸 **Η Πρόκληση των Οθονών:** Αντίθετα με τα PCI/USB, δεν υπάρχει μια ενιαία κεντρική βάση δεδομένων για τα EDID Product Codes των κατασκευαστών οθονών (π.χ. το `5BD3` της LG).
🔸 Ωστόσο, μπορούμε να λύσουμε το πρόβλημα συνδυάζοντας 3 πηγές:

### 🔸 Πηγή Α: UEFI PNP Vendor List (uefi.org)
- **Mapping:** Αντιστοιχίζει το 3-γράμματο πρόθεμα (PNP ID) με τον κατασκευαστή (π.χ. `GSM` -> Goldstar / LG Electronics, `AOC` -> AOC, `DEL` -> Dell).
- **Χρήση:** Μας επιτρέπει να γνωρίζουμε με 100% βεβαιότητα τον κατασκευαστή της οθόνης τοπικά.

### 🔸 Πηγή Β: Snappy Driver Installer Origin (SDIO) Drivers
- **SDIO Driverpacks:** Τα open-source driverpacks του SDIO (π.χ. `DP_Monitor_*.7z`) περιέχουν εκατοντάδες αρχεία `.inf` από επίσημους κατασκευαστές.
- **INF Mapping:** Μέσα σε αυτά τα `.inf` αρχεία υπάρχει η άμεση αντιστοίχιση των Hardware IDs με τα εμπορικά μοντέλα:
  `%LG_27GP850% = LG_27GP850, MONITOR\GSM5BD3`
- **Πρόταση Ενσωμάτωσης:** Μπορούμε να γράψουμε ένα script που θα κάνει parse τις λίστες αυτών των INF αρχείων (ή να χρησιμοποιήσουμε τα indexes του SDIO) για να εξάγουμε μια καθαρή βάση δεδομένων σε μορφή JSON: `HardwareId -> Commercial Model Name`.

### 🔸 Πηγή Γ: Community EDID Dumps (linux-hw/EDID)
- **Δημόσια Repositories:** Υπάρχουν open-source βάσεις δεδομένων στο GitHub που συλλέγουν raw EDID dumps από χιλιάδες χρήστες Linux. Μπορούμε να κάνουμε extract τα Product ID Hex Codes και τα αντίστοιχα Model Names.

---

## 🔵 3. Προτεινόμενη Αρχιτεκτονική (Proposed Workflow)

### 🔧 Φάση 1: Offline Local Database Lookup
1. Το `DeviceCheck` διαβάζει το raw Hardware ID (π.χ. `PCI\VEN_10DE&DEV_2803...` ή `MONITOR\GSM5BD3`).
2. Αναζητά το ID στα τοπικά αρχεία `pci.ids`, `usb.ids` ή στο `monitors.json` (που θα παράγουμε από τα INF).
3. Αν βρεθεί, συμπληρώνει αμέσως το πραγματικό μοντέλο (π.χ. `MSI GeForce RTX 4070 Ti` ή `LG UltraGear 27GP850`) στο Details Panel.

### 🔧 Φάση 2: Online API Fallback (Αν δεν υπάρχει τοπικά)
1. Αν η συσκευή είναι άγνωστη, το σύστημα ρωτάει online APIs (π.χ. `devicehunt.com` ή `pci-ids.ucw.cz/read/PC/...`).
2. Ως έσχατη λύση (last resort), ο Agent χρησιμοποιεί Google Search / AI Overview για να κάνει σύνθεση της ταυτότητας της συσκευής.
