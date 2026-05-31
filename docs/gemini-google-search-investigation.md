# Gemini Investigation Brief: Google Search / AI Overview Retrieval

## Στόχος

Θέλουμε το `DeviceCheck` να βρίσκει σωστά drivers για άγνωστες ή παλιές συσκευές σε Windows PCs.

Το δύσκολο κομμάτι είναι το identity discovery: από στοιχεία τύπου Device Manager/PnP πρέπει να καταλάβουμε το πραγματικό μοντέλο και μετά να πάμε σε official vendor/OEM pages για driver links.

Παράδειγμα local evidence:

```text
FriendlyName  : LG ULTRAGEAR(DisplayPort)
InstanceId    : DISPLAY\GSM5BD3\5&2018DE76&1&UID4354
Status        : OK (Working properly)
HardwareId    : MONITOR\GSM5BD3
Manufacturer  : LG
CompatibleId  : *PNP09FF
Service       : monitor
Driver        : LG 1.0.0.0 (oem19.inf)
```

Με αυτό το raw evidence σε normal Google Search, το AI Overview και τα organic results έδωσαν πολύ χρήσιμη κατεύθυνση για το πραγματικό model family, π.χ. LG UltraGear / `27GP850P-B` variants.

## Τι Θέλουμε Από Το Agent

1. Να χρησιμοποιεί το local Device Manager/PnP evidence σαν search input, όχι generic query τύπου `LG monitor driver`.
2. Να βρίσκει identity hints, ειδικά model names / regional model variants.
3. Να προτιμά official vendor/OEM pages.
4. Να ελέγχει Greece/Europe regional pages πριν από US/global όταν ο vendor έχει regional site.
5. Να μην εμπιστεύεται AI Overview ή snippets σαν τελική αλήθεια.
6. Να επιβεβαιώνει final driver links/version/date σε official vendor/OEM page ή Microsoft Update Catalog fallback.

## Τρέχον Tooling

Το `DeviceCheck` έχει αυτά τα relevant tools:

- `SearchGoogleRendered(query)`: ανοίγει Google Search σε local Chrome/Edge μέσω DevTools και επιστρέφει rendered text, AI Overview hint αν υπάρχει, organic result URLs/snippets, ή reCAPTCHA/block result.
- `SearchGoogleCustom(query)`: official Google Custom Search JSON API, όταν υπάρχουν env vars `GOOGLE_CUSTOM_SEARCH_API_KEY` και `GOOGLE_CUSTOM_SEARCH_CX`. Δίνει URLs/snippets αλλά όχι AI Overview.
- `FetchRenderedUrlText(url, targetText, inputText)`: ανοίγει official vendor/OEM page με DevTools, περιμένει JavaScript content, μπορεί να πατήσει tab/category/search input, και επιστρέφει rendered text + download links.
- `FetchUrlText(url)`: plain HTTP fetch.
- `SearchUpdateCatalog(hardwareId)`: Microsoft Update Catalog fallback.

## Τι Δούλεψε

- Για MSI motherboard support page, `FetchRenderedUrlText` βρήκε official Realtek USB Audio driver από MSI site, με version/date/download URL.
- Για AOC/LG monitor identity, raw Google Search με Device Manager evidence έδωσε χρήσιμο AI Overview και official/regional result URLs.
- Για AOC, regional site matters: Greek page μπορεί να υπάρχει ενώ US page δίνει 404/no result.

## Τι Δεν Δούλεψε

- Generic DuckDuckGo snippets είναι noisy και συχνά άχρηστα.
- Το `SearchGoogleRendered` με automated fresh Chrome profile μπορεί να βγάλει Google `unusual traffic` / reCAPTCHA.
- Το official Google Custom Search API δεν δίνει AI Overview.
- Αν το Gemini βλέπει πολλά search tools, μπορεί να κάνει loop αντί να πάει αμέσως σε official vendor pages.

## Σημαντική Υπόθεση

Πιθανόν το πρόβλημα δεν είναι ότι “Google Search δεν γίνεται ποτέ”. Ίσως το κάνουμε με λάθος τρόπο:

- fresh temporary Chrome profile κάθε φορά,
- unusual command-line flags,
- no persistent cookies/session,
- too-long raw query in URL,
- too many automated launches,
- direct `google.com/search?q=...` navigation instead of normal typed search,
- datacenter/VPN/IP reputation issue,
- missing realistic browser state,
- no human-in-the-loop when CAPTCHA appears.

Δεν θέλουμε να παρακάμψουμε CAPTCHA ή security controls. Θέλουμε αξιόπιστο και acceptable workflow.

## Ερωτήσεις Προς Gemini

1. Ποιος είναι ο πιο αξιόπιστος τρόπος για agentic tool να κάνει Google Search discovery χωρίς να προκαλεί reCAPTCHA;
2. Είναι καλύτερο να χρησιμοποιούμε persistent normal Chrome profile αντί για temporary DevTools profile;
3. Είναι καλύτερο να ανοίγουμε Google home page και να πληκτρολογούμε το query σαν user, αντί για direct `/search?q=` URL;
4. Υπάρχει official ή semi-official API/workflow που δίνει AI Overview ή παρόμοιο model-identity summary;
5. Αν AI Overview δεν είναι API-accessible, ποιο είναι το καλύτερο human-assisted workflow;
6. Πώς να σχεδιάσουμε fallback όταν Google rendered search blocked:
   - να ζητά user interaction;
   - να αποθηκεύει pending query;
   - να δέχεται pasted AI Overview;
   - να συνεχίζει από checkpoint;
7. Πώς πρέπει να αλλάξει το agent prompt ώστε να μη σπαταλά requests σε noisy searches;
8. Για driver discovery, ποια search query strategy είναι καλύτερη;
   - raw Device Manager evidence block,
   - quoted hardware ID + manufacturer,
   - model token extraction,
   - official-domain query,
   - region-specific query.
9. Ποιο minimum evidence πρέπει να πάρει το model πριν επιλέξει final driver answer;
10. Τι logs/checkpoints πρέπει να κρατάμε για να debugάρουμε λάθος result;

## Desired Answer Format

Παρακαλώ απάντησε πρακτικά, σαν system design review:

```text
Recommended workflow:
1. ...
2. ...

Tool changes:
- ...

Prompt changes:
- ...

Browser/Search behavior:
- ...

Fallback and human-assisted flow:
- ...

Risks:
- ...
```

## Non-Negotiable Rules

- Μην προτείνεις bypass CAPTCHA.
- Μην βασίζεις final driver answer σε AI Overview μόνο.
- Μην βασίζεις final answer σε random third-party driver sites.
- Official OEM/vendor source first.
- Regional sites first for Greece/Europe when the product is regional.
- Microsoft Update Catalog is fallback, not primary, when OEM/vendor page exists.
