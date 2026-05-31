# 🔵 Gemini Response: Google Search / AI Overview Retrieval

🔸 **Ημερομηνία:** 2026-05-31
🔸 **Αρχείο Brief:** [gemini-google-search-investigation.md](file:///d:/Users/joty79/scripts/DeviceCheck/docs/gemini-google-search-investigation.md)

---

### 🔵 System Design Review & Απαντήσεις

#### 1. Αξιόπιστο Google Search Discovery
🔸 Ο πιο σταθερός και ασφαλής τρόπος είναι το **Google Custom Search JSON API** (`SearchGoogleCustom`).
🔸 Δεν προκαλεί ποτέ ***reCAPTCHA*** και παρακάμπτει το browser automation.
🔸 Αν το API δεν είναι configured, η χρήση του `SearchGoogleRendered` πρέπει να περιορίζεται σε **1-2 προσπάθειες** ανά εκτέλεση με αυστηρά block detection rules.

#### 2. Persistent Browser Profile vs Temporary Profile
🔸 Η χρήση **Persistent Chrome Profile** είναι ***ΚΡΙΣΙΜΗ***.
🔸 Τα temporary profiles στερούνται cookies, local storage και realistic headers, κάτι που η Google ανιχνεύει άμεσα ως bot behavior.
🔸 Ένα persistent profile συσσωρεύει φυσιολογικό browser state και μειώνει την πιθανότητα εμφάνισης ***anti-bot challenge***.

#### 3. Google Home Typed-Search vs Direct URL
🔸 Η απευθείας πλοήγηση στο `/search?q=...` είναι κλασικό σήμα αυτοματοποιημένου scraper.
🔸 Η έναρξη από το `google.gr` (ή `google.com`), η προσομοίωση πληκτρολόγησης στο input, και το κλικ στο κουμπί αναζήτησης προσφέρουν πολύ μεγαλύτερη αξιοπιστία.

#### 4. Official API για AI Overview
🔸 Επίσημα, το Google Custom Search API **ΔΕΝ** επιστρέφει ***AI Overview***.
🔸 Η μόνη επίσημη εναλλακτική είναι η χρήση του **Gemini API με Google Search Grounding** (όπου το μοντέλο εκτελεί τις αναζητήσεις μέσω της Google υποστηριζόμενο από την υποδομή της).

#### 5. Human-Assisted Workflow για AI Overview
🔸 Όταν το automated search μπλοκάρεται, το DeviceCheck πρέπει να προσφέρει **Human-in-the-Loop Fallback**:
1. Το σύστημα παράγει το optimized search query.
2. Ο χρήστης το ανοίγει στο δικό του κανονικό Chrome με ένα κλικ.
3. Αντιγράφει το ***AI Overview*** text.
4. Το κάνει επικόλληση (paste) στο Details Panel, το οποίο το σώζει στο cache της συσκευής ως έγκυρο evidence.

#### 6. Σχεδιασμός Fallback σε περίπτωση Block
🔸 Όταν ανιχνεύεται reCAPTCHA, ο Agent αποθηκεύει το state ως `PausedBlocked` στο Checkpoint.
🔸 Το script σταματά να καλεί τη Google και συνεχίζει αποκλειστικά με:
- Deterministic vendor candidates.
- Microsoft Update Catalog fallback.
- Pasted AI Overview από τον χρήστη.

#### 7. Prompt Optimization
🔸 Το prompt του Agent πρέπει να επιβάλλει **Strict Hierarchy**:
1. Έλεγχος deterministic candidates με `FetchRenderedUrlText` (π.χ. MSI, LG, AOC support URLs).
2. Χρήση `SearchGoogleCustom` (αν υπάρχει API key).
3. Fallback σε `SearchGoogleRendered` (μόνο μία φορά για identity hints).
4. Fallback σε `SearchUpdateCatalog`.
🔸 Απαγόρευση χρήσης του generic `SearchWeb` (DuckDuckGo) όταν υπάρχουν έγκυρα vendor candidates.

#### 8. Στρατηγική Query για Driver Discovery
🔸 Η βέλτιστη στρατηγική είναι **Hybrid**:
- **Identity Discovery:** Raw Device Manager block + `driver` (εξαιρετικό για AI Overview σύνθεση).
- **Official Pages Search:** Quoted Hardware ID + Manufacturer + `driver site:vendor.com` (π.χ. `"USB\VID_0DB0&PID_CD0E" Realtek site:msi.com`).

#### 9. Minimum Evidence για Final Answer
🔸 Ο Agent δεν πρέπει να δίνει τελική απάντηση χωρίς:
1. **Official Domain Verification:** Το link λήψης πρέπει να ανήκει στο επίσημο domain του κατασκευαστή (π.χ. `download.msi.com`, `dlcdnets.asus.com`).
2. **Version Match:** Επιβεβαίωση της έκδοσης (π.χ. `6.4.0.2443`) και της ημερομηνίας κυκλοφορίας.

#### 10. Logs & Checkpoints για Debugging
🔸 **Trace Logs (`.jsonl`):** Καταγραφή κάθε Gemini step, requested tool, arguments, και tool output.
🔸 **Checkpoint JSON:** Αποθήκευση του messages array, memory (URLs, planning steps), και device metadata για πλήρη αναπαραγωγή.

---

### 🔵 Proposed System Architecture

```text
Recommended workflow:
1. System Evidence Gathering -> Δημιουργία σταθερού Machine & Device ID.
2. Deterministic Check -> Κατασκευή support URLs βάσει PnP/Motherboard signatures.
3. Fetch Official Content -> Χρήση FetchRenderedUrlText στα constructed support pages.
4. Fallback to API Search -> Χρήση SearchGoogleCustom (αν είναι configured).
5. Fallback to Browser Search -> Χρήση SearchGoogleRendered (max 1 run, persistent profile).
6. Human Fallback -> Open browser query & import pasted AI Overview.
7. Verification -> Επιβεβαίωση version/date/domain.
8. Cache Save -> Αποθήκευση στο τοπικό JSON cache.

Tool changes:
- SearchGoogleRendered: Προσθήκη υποστήριξης persistent profile directory.
- SearchGoogleRendered: Υλοποίηση "typed-search" στην αρχική σελίδα της Google.
- DeviceCheck UI: Προσθήκη επιλογής "Import pasted AI Overview" στο Details Panel.

Prompt changes:
- Προσθήκη αυστηρού κανόνα: "Do NOT use generic search engines if a constructed vendor support URL is available."
- Enforce output separation: Official OEM vs Official Vendor vs Catalog vs Web snippet.

Browser/Search behavior:
- Χρήση persistent Chrome/Edge user-data-dir.
- Αποφυγή direct navigation σε search URLs.
- Ρύθμιση ρεαλιστικών locales/headers (el-GR/gr).

Fallback and human-assisted flow:
- checkpoint-based resume σε Pause states.
- Χειροκίνητη εισαγωγή search text/AI Overview από τον χρήστη.

Risks:
- CAPTCHA blocks που διακόπτουν το automation.
- Λανθασμένα regional redirects (π.χ. US support page που επιστρέφει 404 αντί για το GR/EU).
- Λανθασμένο model identification από AI Overviews (χρειάζεται πάντα verification στο official page).
```
