# Atlas OS / Windows 10

## Fix: Δεν ανοίγει το `\\PC_NAME` αλλά ανοίγει το `\\PC_NAME\Share`

---

## Συμπτώματα

- Από άλλο PC:
  - `\\PC_NAME` → *You do not have permission to access*
- Όμως:
  - `\\PC_NAME\Share` ανοίγει κανονικά
- Όλα τα υπόλοιπα φαίνονται σωστά:
  - SMB services OK
  - Firewall OK
  - Network Discovery OK
  - Ίδιες ρυθμίσεις με άλλα PCs
- Το πρόβλημα εμφανίζεται **μόνο σε ένα PC** (συνήθως το main)

---

## Αιτία (πολύ ύπουλη)

Το PC χρησιμοποιεί **local account χωρίς password (blank password)**  
και είναι ενεργοποιημένη η πολιτική:

`Accounts: Limit local account use of blank passwords to console logon only`

Αυτή η ρύθμιση:

- Μπλοκάρει **SMB share enumeration** (`\\PC_NAME`)
- ΔΕΝ μπλοκάρει **direct share access** (`\\PC_NAME\Share`)
- Δεν φαίνεται σε firewall, services ή registry
- Δεν δίνει ξεκάθαρο error

Γι’ αυτό το πρόβλημα φαίνεται «τυχαίο» και είναι δύσκολο να εντοπιστεί.

---

## Λύση (2 λεπτά)

1. Άνοιξε Local Security Policy:
   
   - `Win + R`
   - `secpol.msc`

2. Πήγαινε:
   
   - Local Policies
   - Security Options

3. Βρες:
   
   - `Accounts: Limit local account use of blank passwords to console logon only`

4. Άλλαξε την τιμή σε:
   
   - `Disabled`

5. OK → Close

Συνήθως **δεν χρειάζεται reboot**.  
Αν δεν αλλάξει άμεσα, κάνε restart.

---

## Έλεγχος

Από άλλο PC:

- `\\PC_NAME`

Πρέπει πλέον να:

- ανοίγει κανονικά
- εμφανίζει όλα τα shared folders

---

## Σημειώσεις ασφάλειας

- Το πρόβλημα εμφανίζεται **μόνο αν**:
  - χρησιμοποιείς local account
  - χωρίς password
- Αν βάλεις password στον λογαριασμό:
  - μπορείς να αφήσεις αυτή τη ρύθμιση `Enabled`
  - και το `\\PC_NAME` θα λειτουργεί κανονικά

---

## TL;DR (για future-you)

- `\\PC_NAME` δεν ανοίγει
- `\\PC_NAME\Share` ανοίγει
- Έλεγξε ΠΡΩΤΑ:
  - `Accounts: Limit local account use of blank passwords to console logon only`
- Αν έχεις blank password:
  - βάλε το `Disabled`
  - ή βάλε password και άφησέ το `Enabled`

---

## Context

- Atlas OS
- Hardened SMB / Network configuration
- Το πρόβλημα εμφανίζεται συχνά μόνο σε ένα PC
- Δεν είναι bug των Windows αλλά security policy behavior
