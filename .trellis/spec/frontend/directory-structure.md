# Directory Structure

> How frontend code is organized in this project.

---

## Overview

<!--
Document your project's frontend directory structure here.

Questions to answer:
- Where do components live?
- How are features/modules organized?
- Where are shared utilities?
- How are assets organized?
-->

The mobile client lives in `mobile_app/` and is a Flutter application. Keep UI, business rules, storage, OCR post-processing, and native bridge boundaries separated under `mobile_app/lib/src/`.

---

## Directory Layout

```
mobile_app/lib/
├── main.dart
└── src/
    ├── application/   # Dart business use cases and in-memory test service
    ├── data/          # SQLite schema and local persistence
    ├── domain/        # Plain Dart models
    ├── ocr/           # PP-Structure/OCR post-processing
    ├── platform/      # MethodChannel contracts
    └── ui/            # Flutter screens/widgets
```

---

## Module Organization

<!-- How should new features be organized? -->

UI code may call application/data services, but it must not embed SQL, OCR parsing rules, or platform channel payload parsing. Put cross-platform business behavior in Dart services and keep Android/iOS implementation details behind `src/platform/` channels.

---

## Naming Conventions

<!-- File and folder naming rules -->

Use lowercase snake_case Dart filenames and directory names. Keep feature-independent models in `domain/`; do not duplicate model shapes inside UI widgets.

---

## Examples

<!-- Link to well-organized modules as examples -->

Current reference files:

* `mobile_app/lib/src/ui/app_home.dart`
* `mobile_app/lib/src/data/local_inventory_database.dart`
* `mobile_app/lib/src/ocr/pp_structure_post_processor.dart`

## Online Read-only Viewer

`frontend/` is the Vue/TypeScript browser console, separate from Flutter. Shared inventory list/detail rendering lives in `src/components/InventoryViewer.vue`; authenticated blob image ownership lives in `ProtectedImage.vue`. `src/api/view.ts` owns wire types. `store/auth.ts` and `utils/session-scope.ts` capture a generation so old responses cannot revive after A→B→A account/shop switches. Inventory views are read-only; shop membership approval remains writable. Run `npm --prefix frontend test` and `npm --prefix frontend run build`.
