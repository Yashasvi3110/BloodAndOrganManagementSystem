-- -----------------------------------------------------------------
-- SQL Schema for Blood Bank & Organ Donation Management System
-- Database: Oracle SQL
-- -----------------------------------------------------------------

-- === CLEANUP SECTION (Direct DROP Statements) ===
-- Standard practice to drop all objects before re-creation.
-- WARNING: You may see errors (e.g., ORA-04080) if objects haven't been created yet.

-- Drop Triggers (Includes the new TRG_UPDATE_ORGAN_STOCK_ON_DONATION)
DROP TRIGGER TRG_UPDATE_BLOOD_USAGE;
DROP TRIGGER TRG_UPDATE_BLOOD_STOCK;
DROP TRIGGER TRG_UPDATE_ORGAN_STOCK; -- Drops the usage decrement trigger
DROP TRIGGER TRG_UPDATE_ORGAN_STOCK_ON_DONATION; -- Drops the donation increment trigger (FIXED)
DROP TRIGGER TRG_DONOR_INTERVAL; -- Assuming this might be used later

-- Drop Views
DROP VIEW V_CRITICAL_BLOOD_STOCK;
DROP VIEW V_DONOR_LAST_DONATION;

-- Drop Procedures
DROP PROCEDURE SP_RECORD_ORGAN_DONATION;
DROP PROCEDURE SP_RECORD_BLOOD_USAGE;
DROP PROCEDURE SP_RECORD_BLOOD_DONATION;
DROP PROCEDURE SP_GENERATE_MONTHLY_REPORT;

-- Drop Tables
DROP TABLE ORGANUSAGELOG CASCADE CONSTRAINTS;
DROP TABLE BLOODUSAGELOG CASCADE CONSTRAINTS;
DROP TABLE BLOODDONATIONLOG CASCADE CONSTRAINTS;
DROP TABLE ORGANDONATIONLOG CASCADE CONSTRAINTS;
DROP TABLE MONTHLY_REPORT CASCADE CONSTRAINTS;
DROP TABLE ORGANSTOCK CASCADE CONSTRAINTS;
DROP TABLE BLOODSTOCK CASCADE CONSTRAINTS;
DROP TABLE PATIENT CASCADE CONSTRAINTS;
DROP TABLE DONOR CASCADE CONSTRAINTS;


-- ------------------
-- 1. TABLES (Using GENERATED ALWAYS AS IDENTITY)
-- ------------------

-- DONOR TABLE
CREATE TABLE Donor (
  donor_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name VARCHAR2(100) NOT NULL,
  blood_group VARCHAR2(3) NOT NULL, -- e.g., 'A+', 'O-'
  contact_number VARCHAR2(15),
  is_organ_donor NUMBER(1) DEFAULT 0, -- 1 if also an organ donor, 0 otherwise
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- PATIENT TABLE
CREATE TABLE Patient (
  patient_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name VARCHAR2(100) NOT NULL,
  blood_group VARCHAR2(3) NOT NULL,
  hospital VARCHAR2(100),
  contact_number VARCHAR2(15),
  resource_needed VARCHAR2(50) NOT NULL, -- 'Blood' or an organ name like 'Kidney'
  is_urgent NUMBER(1) DEFAULT 0,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- BLOOD STOCK TABLE
CREATE TABLE BloodStock (
  blood_group VARCHAR2(3) NOT NULL,
  component VARCHAR2(20) NOT NULL, -- e.g., 'Whole', 'Platelets', 'Plasma'
  units_available NUMBER(10) DEFAULT 0 NOT NULL,
  critical_level NUMBER(10) DEFAULT 10,
  last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (blood_group, component)
);

-- ORGAN STOCK TABLE (Uses organ_name as PK for simplicity)
CREATE TABLE OrganStock (
  organ_name VARCHAR2(50) PRIMARY KEY, -- e.g., 'Kidney', 'Heart', 'Liver'
  hla_type VARCHAR2(10) NOT NULL,
  units_available NUMBER(5) DEFAULT 0 NOT NULL,
  last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE BloodDonationLog (
  log_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  donor_id NUMBER NOT NULL,
  component VARCHAR2(20) DEFAULT 'Whole' NOT NULL,
  units_donated NUMBER(5) NOT NULL,
  donation_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
  CONSTRAINT fk_bdl_donor FOREIGN KEY (donor_id) REFERENCES Donor(donor_id) ON DELETE CASCADE
);

CREATE TABLE BloodUsageLog (
  usage_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  component VARCHAR2(20) NOT NULL,
  units_used NUMBER(5) NOT NULL,
  patient_id NUMBER NOT NULL,
  usage_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
  CONSTRAINT fk_bul_patient FOREIGN KEY (patient_id) REFERENCES Patient(patient_id)
);


-- ORGAN DONATION LOG TABLE
CREATE TABLE OrganDonationLog (
  log_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  donor_id NUMBER NOT NULL,
  organ_name VARCHAR2(50) NOT NULL,
  donation_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
  status VARCHAR2(20) DEFAULT 'Available' NOT NULL, -- 'Available', 'Used', 'Discarded'
  CONSTRAINT fk_odl_donor FOREIGN KEY (donor_id) REFERENCES Donor(donor_id) ON DELETE CASCADE,
  CONSTRAINT fk_odl_organ FOREIGN KEY (organ_name) REFERENCES OrganStock(organ_name)
);

-- ORGAN USAGE LOG TABLE
CREATE TABLE OrganUsageLog (
  usage_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  organ_name VARCHAR2(50) NOT NULL,
  patient_id NUMBER NOT NULL,
  usage_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
  CONSTRAINT fk_oul_organ FOREIGN KEY (organ_name) REFERENCES OrganStock(organ_name),
  CONSTRAINT fk_oul_patient FOREIGN KEY (patient_id) REFERENCES Patient(patient_id)
);

-- MONTHLY REPORT TABLE
CREATE TABLE Monthly_Report (
  report_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  category VARCHAR2(15) NOT NULL, -- 'Blood Donation', 'Blood Usage', or 'Organ'
  report_month NUMBER(2) NOT NULL,
  report_year NUMBER(4) NOT NULL,
  item_type VARCHAR2(50) NOT NULL, -- Blood group or Organ name
  component VARCHAR2(20),
  total_units NUMBER NOT NULL
);

-- ------------------
-- 2. TRIGGERS (Auto-update stock on donation/usage)
-- ------------------

-- Trigger 1: For updating BloodStock after a BloodDonationLog INSERT (Increment stock)
CREATE OR REPLACE TRIGGER TRG_UPDATE_BLOOD_STOCK
AFTER INSERT ON BloodDonationLog
FOR EACH ROW
BEGIN
  -- Derive donor's blood group from Donor table, then MERGE into BloodStock (UPSERT)
  DECLARE
    v_bg VARCHAR2(3);
  BEGIN
    SELECT blood_group INTO v_bg FROM Donor WHERE donor_id = :NEW.donor_id;

    MERGE INTO BloodStock B
    USING DUAL ON (B.blood_group = v_bg AND B.component = :NEW.component)
    WHEN MATCHED THEN
      UPDATE SET B.units_available = B.units_available + :NEW.units_donated,
           B.last_updated = SYSDATE
    WHEN NOT MATCHED THEN
      INSERT (blood_group, component, units_available)
      VALUES (v_bg, :NEW.component, :NEW.units_donated);
  END;
END;
/

-- Trigger 2: For updating BloodStock after a BloodUsageLog INSERT (Decrement stock and validate)
CREATE OR REPLACE TRIGGER TRG_UPDATE_BLOOD_USAGE
AFTER INSERT ON BloodUsageLog
FOR EACH ROW
DECLARE
  v_current_stock NUMBER;
  v_bg VARCHAR2(3);
BEGIN
  -- Derive the patient's blood group, then check and decrement corresponding stock
  BEGIN
    SELECT blood_group INTO v_bg FROM Patient WHERE patient_id = :NEW.patient_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20002, 'Patient ID ' || :NEW.patient_id || ' not found.');
  END;

  -- Check current stock level and lock the row for the transaction
  SELECT units_available INTO v_current_stock
  FROM BloodStock
  WHERE blood_group = v_bg AND component = :NEW.component
  FOR UPDATE OF units_available NOWAIT;

  -- Check if enough stock is available before decrementing
  IF v_current_stock < :NEW.units_used THEN
    -- Raise an application error to prevent the transaction (and rollback the log insertion)
    RAISE_APPLICATION_ERROR(-20001, 'Insufficient stock available for ' || v_bg || ' ' || :NEW.component || '. Requested: ' || :NEW.units_used || ', Available: ' || v_current_stock);
  END IF;

  -- Decrement the stock
  UPDATE BloodStock
  SET units_available = units_available - :NEW.units_used,
    last_updated = SYSDATE
  WHERE blood_group = v_bg AND component = :NEW.component;
END;
/

-- Trigger 3: For updating OrganStock after an OrganUsageLog INSERT (Decrement stock by 1)
CREATE OR REPLACE TRIGGER TRG_UPDATE_ORGAN_STOCK
AFTER INSERT ON OrganUsageLog
FOR EACH ROW
BEGIN
  UPDATE OrganStock
  SET units_available = units_available - 1,
    last_updated = SYSDATE
  WHERE organ_name = :NEW.organ_name;
END;
/

-- Trigger 4: For updating OrganStock after an OrganDonationLog INSERT (Increment stock by 1)
CREATE OR REPLACE TRIGGER TRG_UPDATE_ORGAN_STOCK_ON_DONATION
AFTER INSERT ON OrganDonationLog
FOR EACH ROW
BEGIN
  -- Increment the stock for the donated organ
  UPDATE OrganStock
  SET units_available = units_available + 1,
    last_updated = SYSDATE
  WHERE organ_name = :NEW.organ_name;
END;
/


-- ------------------
-- 3. VIEWS
-- ------------------

-- View to see the last donation date for each donor
CREATE OR REPLACE VIEW V_DONOR_LAST_DONATION AS
SELECT
  d.donor_id,
  d.name,
  MAX(bdl.donation_date) AS last_blood_donation_date,
  MAX(odl.donation_date) AS last_organ_donation_date
FROM Donor d
LEFT JOIN BloodDonationLog bdl ON d.donor_id = bdl.donor_id
LEFT JOIN OrganDonationLog odl ON d.donor_id = odl.donor_id
GROUP BY d.donor_id, d.name;

-- View to highlight blood stock levels below critical threshold
CREATE OR REPLACE VIEW V_CRITICAL_BLOOD_STOCK AS
SELECT
  blood_group,
  component,
  units_available,
  critical_level,
  (critical_level - units_available) AS deficit
FROM BloodStock
WHERE units_available < critical_level;


-- ------------------
-- 4. STORED PROCEDURES
-- ------------------

-- Procedure 1: Record a Blood Donation
CREATE OR REPLACE PROCEDURE SP_RECORD_BLOOD_DONATION (
  p_donor_id   IN NUMBER,
  p_units_donated IN NUMBER,
  p_component   IN VARCHAR2 DEFAULT 'Whole'
)
AS
  v_units_donated NUMBER := p_units_donated;
BEGIN
  -- 1. Insert into BloodDonationLog (Trigger TRG_UPDATE_BLOOD_STOCK handles stock update)
  INSERT INTO BloodDonationLog (donor_id, component, units_donated, donation_date)
  VALUES (p_donor_id, p_component, v_units_donated, SYSDATE);

  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END;
/

-- Procedure 2: Record Blood Usage (Calls new log table, trigger handles stock)
CREATE OR REPLACE PROCEDURE SP_RECORD_BLOOD_USAGE (
  p_patient_id  IN NUMBER,
  p_component   IN VARCHAR2,
  p_units_used  IN NUMBER
)
AS
BEGIN
  -- Insert into BloodUsageLog. The trigger TRG_UPDATE_BLOOD_USAGE handles stock update and validation.
  INSERT INTO BloodUsageLog (patient_id, component, units_used, usage_date)
  VALUES (p_patient_id, p_component, p_units_used, SYSDATE);

  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    -- Errors like insufficient stock (from trigger) will propagate here
    RAISE;
END;
/

-- Procedure 3: Record Organ Donation
CREATE OR REPLACE PROCEDURE SP_RECORD_ORGAN_DONATION (
  p_donor_id   IN NUMBER,
  p_organ_name IN VARCHAR2
)
AS
  v_is_organ_donor NUMBER(1);
BEGIN
  -- 1. Check if the donor is registered as an organ donor
  BEGIN
    SELECT is_organ_donor INTO v_is_organ_donor
    FROM Donor
    WHERE donor_id = p_donor_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20002, 'Donor ID ' || p_donor_id || ' not found.');
  END;

  -- 2. Validate if the donor is authorized to donate organs
  IF v_is_organ_donor = 0 THEN
    RAISE_APPLICATION_ERROR(-20003, 'Donor ID ' || p_donor_id || ' is not registered as an organ donor.');
  END IF;

  -- 3. Insert into OrganDonationLog. (Trigger TRG_UPDATE_ORGAN_STOCK_ON_DONATION handles stock update)
  INSERT INTO OrganDonationLog (donor_id, organ_name, donation_date, status)
  VALUES (p_donor_id, p_organ_name, SYSDATE, 'Available');

  COMMIT;

EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END;
/


-- Procedure 4 (Updated): Generate Monthly Report (Now includes Blood Usage)
CREATE OR REPLACE PROCEDURE SP_GENERATE_MONTHLY_REPORT(p_month NUMBER, p_year NUMBER)
AS
BEGIN
  -- Clean up previous report for this month/year
  DELETE FROM Monthly_Report WHERE report_month = p_month AND report_year = p_year;

  -- Blood DONATION report: join to Donor to obtain blood_group (normalized schema)
  INSERT INTO Monthly_Report (category, report_month, report_year, item_type, component, total_units)
  SELECT 'Blood Donation', p_month, p_year, d.blood_group, bdl.component, SUM(bdl.units_donated)
  FROM BloodDonationLog bdl
  JOIN Donor d ON bdl.donor_id = d.donor_id
  WHERE EXTRACT(MONTH FROM bdl.donation_date) = p_month
    AND EXTRACT(YEAR FROM bdl.donation_date) = p_year
  GROUP BY d.blood_group, bdl.component;

  -- Blood USAGE report: join to Patient to obtain blood_group
  INSERT INTO Monthly_Report (category, report_month, report_year, item_type, component, total_units)
  SELECT 'Blood Usage', p_month, p_year, p.blood_group, bul.component, SUM(bul.units_used)
  FROM BloodUsageLog bul
  JOIN Patient p ON bul.patient_id = p.patient_id
  WHERE EXTRACT(MONTH FROM bul.usage_date) = p_month
    AND EXTRACT(YEAR FROM bul.usage_date) = p_year
  GROUP BY p.blood_group, bul.component;

  -- Organ Donation report
  INSERT INTO Monthly_Report (category, report_month, report_year, item_type, component, total_units)
  SELECT 'Organ Donation', p_month, p_year, od.organ_name, NULL, COUNT(*)
  FROM OrganDonationLog od
  WHERE EXTRACT(MONTH FROM od.donation_date) = p_month
    AND EXTRACT(YEAR FROM od.donation_date) = p_year
  GROUP BY od.organ_name;

  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    RAISE;
END;
/


-- ------------------
-- 5. INITIAL DATA SEEDING
-- ------------------

-- Seed initial BloodStock
INSERT INTO BloodStock (blood_group, component, units_available, critical_level) VALUES
('O+', 'Whole', 15, 5);
INSERT INTO BloodStock (blood_group, component, units_available, critical_level) VALUES
('A+', 'Whole', 8, 10);
INSERT INTO BloodStock (blood_group, component, units_available, critical_level) VALUES
('B-', 'Whole', 2, 3);
INSERT INTO BloodStock (blood_group, component, units_available, critical_level) VALUES
('AB+', 'Whole', 20, 5);
-- Add Platelets stock
INSERT INTO BloodStock (blood_group, component, units_available, critical_level) VALUES
('O+', 'Platelets', 5, 2);

-- Seed initial OrganStock
INSERT INTO OrganStock (organ_name, hla_type, units_available) VALUES
('Kidney', 'A2B5', 2);
INSERT INTO OrganStock (organ_name, hla_type, units_available) VALUES
('Liver', 'C1D4', 1);
INSERT INTO OrganStock (organ_name, hla_type, units_available) VALUES
('Heart', 'E5F6', 0);

-- Seed initial Donors
INSERT INTO Donor (name, blood_group, contact_number, is_organ_donor) VALUES
('Blood Donor Jane', 'A+', '9876543210', 0);
INSERT INTO Donor (name, blood_group, contact_number, is_organ_donor) VALUES
('Organ Donor Mike', 'O-', '9988776655', 1);
INSERT INTO Donor (name, blood_group, contact_number, is_organ_donor) VALUES
('New Donor Ken', 'B+', '5551234567', 0);

INSERT INTO BloodDonationLog (donor_id, blood_group, component, units_donated, donation_date) VALUES
(1, 'A+', 'Whole', 1, SYSDATE - 100);
INSERT INTO BloodDonationLog (donor_id, component, units_donated, donation_date) VALUES
(1, 'Whole', 1, SYSDATE - 100);
INSERT INTO BloodDonationLog (donor_id, component, units_donated, donation_date) VALUES
(2, 'Whole', 1, SYSDATE - 10);
INSERT INTO BloodDonationLog (donor_id, component, units_donated, donation_date) VALUES
(1, 'Platelets', 1, SYSDATE - 30);

-- Seed an organ donation log for Mike (Trigger will update stock)
INSERT INTO OrganDonationLog (donor_id, organ_name, donation_date, status) VALUES
(2, 'Kidney', SYSDATE - 50, 'Available');

INSERT INTO Patient (name, blood_group, hospital, contact_number, resource_needed, is_urgent) VALUES
('Patient Zoe', 'A+', 'City Hospital', '1112223334', 'Blood', 1);
INSERT INTO Patient (name, blood_group, hospital, contact_number, resource_needed, is_urgent) VALUES
('Patient Tom', 'B-', 'General Clinic', '4445556667', 'Kidney', 0);
INSERT INTO Patient (name, blood_group, hospital, contact_number, resource_needed, is_urgent) VALUES
('Patient Eva', 'O+', 'Central Hospital', '3334445556', 'Blood', 0);

Commit;