# Surplus Food Rescue: Real-Time Perishable Food Discovery & Preservation System

> **CECS202 Database Management Systems Mini Project (Experiments 7–10)**  
> **Bharatiya Vidya Bhavan's Sardar Patel Institute of Technology (SPIT)**  
> **Department of Computer Engineering · Academic Year 2026**

---

## 👥 Team Information (Batch B2)

| Student Name | UID |
| :--- | :--- |
| **Sameel Kazi** | 2025300107 |
| **Pradhyun Kembhavi** | 2025300109 |
| **Adeeb Khan** | 2025300110 |

---

## 📖 Executive Summary

Unlike packaged dry groceries or pharmaceuticals whose shelf lives extend for months or years, prepared commercial food perishes within hours. A batch of cooked chicken curry prepared at 3:00 PM becomes bacteriologically hazardous by 9:00 PM. 

**Surplus Food Rescue** is an enterprise-grade, relational database system designed to synchronize surplus food discovery, strict perishable shelf-life windows, First-Expiry-First-Out (FEFO) stock allocation, and 45-minute reservation holds between food donors (restaurants, bakeries, caterers, supermarkets) and receivers (individuals, students, verified NGOs).

---

## 🏛️ System Architecture & Database Overview

- **Target RDBMS**: MySQL 8.0.16+ / 9.4.0 (InnoDB Engine, ACID-Compliant)
- **Normal Form**: Strictly Normalized up to **Third Normal Form (3NF)** with 0 transitive or partial dependencies.
- **Relational Footprint**: **15 Normalized Relations**
  - **Core Entities**: `Admin`, `Donor`, `Receiver`, `Food_Item`, `Allergen`
  - **Weak Entities**: `Donor_Hours`, `Food_Batch`
  - **Associative / Junction Tables**: `Listing`, `Item_Allergen`, `Reservation_Item`, `Reservation_Batch`
  - **Transactional & Audit Engines**: `Reservation`, `Batch_Log`, `Search_Log`, `Feedback`
- **Programmable Database Objects**:
  - `4 Stored Functions`: `fn_now()`, `fn_final_price()`, `fn_available_units()`, `fn_urgency()`
  - `4 Relational Views`: `public_listing`, `donor_open_now`, `expiring_soon`, `unmet_demand`
  - `6 Active Triggers`: Automatic stock logging, shelf-life integrity rejection, past-expiry prevention, anti-hoarding limits, mutation lock on closed reservations, rating eligibility verification.
  - `8 Stored Procedures & Transactions`: `create_reservation()`, `add_reservation_item()`, `collect_reservation()`, `cancel_reservation()`, `release_expired_reservations()`, `reserve_basket()` (atomic multi-item reservation with `SELECT ... FOR UPDATE` and `ROLLBACK`).

---

## 📂 Repository Structure & Submission Artifacts

```
.
├── reports/                                # Official Academic Submission Reports & Schematics
│   ├── Phase_I_Surplus_Food_Rescue.pdf     # Stage 1-3 Report (Problem Statement, ER Modeling, 3NF Proof)
│   ├── Phase_I_Surplus_Food_Rescue.docx    # Editable Microsoft Word Source
│   ├── Phase_II_Surplus_Food_Rescue.pdf    # 20 Relational Queries with Authentic Terminal Screenshots
│   ├── Phase_II_Surplus_Food_Rescue.docx   # Editable Microsoft Word Source
│   ├── Phase_III_Surplus_Food_Rescue.pdf   # Functions, Views, Triggers, Procedures, ACID & RBAC
│   ├── Phase_III_Surplus_Food_Rescue.docx  # Editable Microsoft Word Source
│   ├── ER_Diagram_Surplus_Food_Rescue.pdf  # Dedicated Full HD Vector 16:9 Architectural Diagram
│   └── er_diagram.png                      # 4K UHD Architectural Diagram (3840x2160)
│
├── sql/                                    # Academic MySQL Relational Scripts (Exp 7 to 10)
│   ├── exp7_schema_and_data.sql            # DDL (15 Normalized Tables with Constraints) + Sample Data
│   ├── exp8_queries.sql                    # 20 Queries (Joins, Aggregates, Relational Division)
│   ├── exp9_programming.sql                # 4 Functions, 4 Views, 6 Triggers, 8 Stored Procedures
│   ├── exp9_tests.sql                      # 19 Functional Test Suites with Automated Assertions
│   ├── exp10_transactions_privileges.sql   # ACID Transactions (reserve_basket) & 3 RBAC User Roles
│   └── role_tests/                         # Verification Suites for Role Privileges
│       ├── test_as_admin.sql
│       ├── test_as_donor.sql
│       └── test_as_receiver.sql
│
├── public/                                 # Interactive Neo-Brutalist Light Web Portal
│   ├── index.html                          # Semantic Single Page Application
│   ├── style.css                           # High-Contrast Neo-Brutalist Light Stylesheet
│   └── app.js                              # Client-Side Application Controller
│
├── server.js                               # Node.js + Express Backend with Cloud MySQL / Env Support
├── package.json                            # Node.js Project Manifest & Dependencies
├── package-lock.json                       # Dependency Lockfile
├── vercel.json                             # Optional Vercel Serverless Configuration
└── README.md                               # Project Documentation & Viva Voce Guide
```

---

## ⚡ Quickstart: Local Execution Guide

### 1. Prerequisites
- **MySQL Server 8.0+ / 9.x** running on `localhost:3306`
- **Node.js (v18+)** and `npm`

### 2. Initialize Database & Populate Data
Execute the SQL files in chronological sequence from the project root:

```bash
# 1. Create database, tables, and sample operational records
mysql -u root -p < sql/exp7_schema_and_data.sql

# 2. Test 20 relational experiment queries (Joins, Aggregations, Subqueries)
mysql -u root -p -t < sql/exp8_queries.sql

# 3. Compile functions, views, triggers, and stored procedures
mysql -u root -p < sql/exp9_programming.sql

# 4. Verify functional triggers and procedures (19 test cases)
mysql -u root -p -t --force < sql/exp9_tests.sql

# 5. Compile ACID transactions and provision Role-Based Access Control (RBAC) users
mysql -u root -p -t --force < sql/exp10_transactions_privileges.sql
```

### 3. Launch Full-Stack Web Application
```bash
# Install required Node.js dependencies
npm install

# Start the application server
node server.js
```
Open **`http://localhost:3001`** in any modern web browser to access the live portal.

---

## 🌐 Live Cloud Deployment Architecture

The application is architected with a 12-factor configuration pattern via environment variables (`DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `DB_SSL`):

```
┌───────────────────────────────────────────────┐       ┌──────────────────────────────────────────────┐
│  Render / Railway / Vercel (Web Service)      │       │  TiDB Cloud / Aiven (Free Managed MySQL)     │
│  • Node.js + Express API Backend              │ ────> │  • Port 3306 / 4000 (MySQL 8.0/9.0 Protocol)  │
│  • Neo-Brutalist Single Page Frontend         │ (SSL) │  • 15 Normalized Tables + FEFO Engine        │
│  • Zero-Build Static Asset Delivery           │       │  • Fully Managed Cloud Persistence           │
└───────────────────────────────────────────────┘       └──────────────────────────────────────────────┘
```

---

## 🎓 Viva Voce Key Defense Highlights

1. **Deterministic Perishability via `fn_now()`**:
   Because prepared food perishes in hours, all stored objects invoke `fn_now()` instead of system `NOW()`. During demonstrations, setting `@demo_now = '2026-11-05 20:30:00'` ensures tests yield consistent, reproducible results.
2. **First-Expiry-First-Out (FEFO) Allocation**:
   Unlike standard FIFO (First-In, First-Out), perishable rescue requires **FEFO**. `add_reservation_item()` and `reserve_basket()` order lots by `best_before ASC`, automatically splitting a multi-portion order across multiple batches if necessary.
3. **Relational Division (Q19)**:
   Implemented cleanly using `GROUP BY` and `HAVING COUNT(DISTINCT l.item_id) = (SELECT COUNT(*) FROM Reservation_Item WHERE reservation_id = 1)` to identify which donors can fulfill an entire bulk request.
4. **Anti-Hoarding Integrity Trigger**:
   An `AFTER INSERT` trigger on `Reservation_Item` audits active concurrent holds for individual/student accounts, blocking hoarders from exceeding the 6-portion ceiling while granting verified NGOs unlimited relief capacity.
5. **ACID Multi-Item Basket Isolation**:
   `reserve_basket()` implements row-level locking via `SELECT quantity FROM Food_Batch WHERE ... FOR UPDATE`. If any single item in a multi-item basket lacks sufficient inventory, an `EXIT HANDLER FOR SQLEXCEPTION` triggers a complete `ROLLBACK`, guaranteeing zero orphaned holds.
6. **Granular Column-Level Privileges**:
   Administrative staff are granted update privileges strictly on `Donor(status, verified_by, verified_at)`, preventing unauthorized mutation of donor commercial terms or banking credentials.

---

## 📜 License & Academic Integrity
Developed as part of the academic curriculum for CECS202 Database Management Systems at Sardar Patel Institute of Technology. All code and documentation are intended for academic evaluation.
