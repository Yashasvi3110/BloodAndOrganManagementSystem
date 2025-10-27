import oracledb
from flask import Flask, request, jsonify, render_template
from flask_cors import CORS
import datetime

# --- IMPORTANT: CONFIGURE YOUR ORACLE CONNECTION HERE ---\
# NOTE: The provided credentials below are examples.
ORACLE_CONFIG = {
    "user": "system",       # <-- UPDATE THIS
    "password": "Yash2005", # <-- UPDATE THIS
    "dsn": "localhost:1521/XEPDB1"    # <-- UPDATE THIS (if needed for your setup)
}

app = Flask(__name__)
# Allow CORS for frontend running on a different port/location
CORS(app)

@app.route('/')
def home():
    # It tries to find 'index.html' inside the 'templates' folder
    # NOTE: In the Canvas environment, this will serve the root HTML file.
    return render_template('index.html')

def get_db_connection():
    """Establishes and returns a connection to the Oracle database."""
    try:
        # Set Thick mode for local connections if needed, though Thin mode is often default and works
        # oracledb.init_oracle_client()
        connection = oracledb.connect(**ORACLE_CONFIG)
        return connection
    except oracledb.Error as e:
        # Log the detailed error (optional)
        print(f"Database connection failed: {e}")
        # Re-raise or handle the error appropriately
        raise ConnectionError("Could not connect to the database.")

def row_to_dict(cursor, row):
    """Converts a database row into a dictionary using cursor description."""
    if row is None:
        return None
    data = {}
    for i, col in enumerate(cursor.description):
        data[col[0].lower()] = row[i]
    return data

# --- API ROUTES ---

@app.route('/api/stock', methods=['GET'])
def get_stock():
    conn = None
    try:
        conn = get_db_connection()
        cursor = conn.cursor()

        # Fetch Blood Stock
        cursor.execute("SELECT blood_group, component, units_available, last_updated FROM BloodStock ORDER BY blood_group, component")
        blood_stock_rows = cursor.fetchall()
        blood_stock = [row_to_dict(cursor, row) for row in blood_stock_rows]

        # Fetch Organ Stock
        cursor.execute("SELECT organ_name, units_available, last_updated FROM OrganStock ORDER BY organ_name")
        organ_stock_rows = cursor.fetchall()
        organ_stock = [row_to_dict(cursor, row) for row in organ_stock_rows]

        return jsonify({
            "blood_stock": blood_stock,
            "organ_stock": organ_stock
        })

    except ConnectionError:
        return jsonify({"error": "Database connection failed."}), 500
    except oracledb.DatabaseError as db_error:
        error, = db_error.args
        print(f"Database Error: {error.message}")
        return jsonify({"error": f"Failed to fetch stock data: {error.message}"}), 500
    finally:
        if conn:
            conn.close()

@app.route('/api/donors', methods=['GET'])
def get_donors():
    conn = None
    try:
        conn = get_db_connection()
        cursor = conn.cursor()

        # Fetch all donors
        cursor.execute("SELECT donor_id, name, blood_group, contact_number, is_organ_donor FROM Donor ORDER BY donor_id")
        donor_rows = cursor.fetchall()
        donors = [row_to_dict(cursor, row) for row in donor_rows]

        return jsonify(donors)

    except ConnectionError:
        return jsonify({"error": "Database connection failed."}), 500
    except oracledb.DatabaseError as db_error:
        error, = db_error.args
        print(f"Database Error: {error.message}")
        return jsonify({"error": f"Failed to fetch donors: {error.message}"}), 500
    finally:
        if conn:
            conn.close()


@app.route('/api/donors/<int:donor_id>', methods=['DELETE'])
def delete_donor(donor_id):
    conn = None
    try:
        conn = get_db_connection()
        cursor = conn.cursor()

        cursor.execute("DELETE FROM Donor WHERE donor_id = :id", {'id': donor_id})
        if cursor.rowcount == 0:
            return jsonify({"error": f"Donor ID {donor_id} not found."}), 404

        conn.commit()
        return jsonify({"message": f"Donor ID {donor_id} deleted successfully."})

    except ConnectionError:
        return jsonify({"error": "Database connection failed."}), 500
    except oracledb.DatabaseError as db_error:
        error, = db_error.args
        if conn:
            conn.rollback()
        return jsonify({"error": f"Failed to delete donor: {error.message}"}), 400
    finally:
        if conn:
            conn.close()

# FIX: Added the missing /api/patients GET endpoint to resolve the 500 error.
@app.route('/api/patients', methods=['GET'])
def get_patients():
    conn = None
    try:
        conn = get_db_connection()
        cursor = conn.cursor()

        # Fetch all patients
        cursor.execute("SELECT patient_id, name, blood_group, hospital, contact_number, resource_needed, is_urgent FROM Patient ORDER BY patient_id")
        patient_rows = cursor.fetchall()
        patients = [row_to_dict(cursor, row) for row in patient_rows]

        return jsonify(patients)

    except ConnectionError:
        return jsonify({"error": "Database connection failed."}), 500
    except oracledb.DatabaseError as db_error:
        error, = db_error.args
        print(f"Database Error on /api/patients: {error.message}")
        return jsonify({"error": f"Failed to fetch patients: {error.message}"}), 500
    except Exception as e:
        print(f"General Error on /api/patients: {e}")
        return jsonify({"error": f"An unexpected error occurred: {e}"}), 500
    finally:
        if conn:
            conn.close()


@app.route('/api/patients/<int:patient_id>', methods=['DELETE'])
def delete_patient(patient_id):
    conn = None
    try:
        conn = get_db_connection()
        cursor = conn.cursor()

        # First remove dependent records that reference this patient to avoid FK constraint errors.
        # Depending on your retention policy you may prefer to archive logs instead of deleting.
        cursor.execute("DELETE FROM BloodUsageLog WHERE patient_id = :id", {'id': patient_id})
        cursor.execute("DELETE FROM OrganUsageLog WHERE patient_id = :id", {'id': patient_id})

        # Now delete the patient record
        cursor.execute("DELETE FROM Patient WHERE patient_id = :id", {'id': patient_id})
        if cursor.rowcount == 0:
            # If no patient row was deleted, nothing to commit
            return jsonify({"error": f"Patient ID {patient_id} not found."}), 404

        conn.commit()
        return jsonify({"message": f"Patient ID {patient_id} and related usage logs deleted successfully."})

    except ConnectionError:
        return jsonify({"error": "Database connection failed."}), 500
    except oracledb.DatabaseError as db_error:
        error, = db_error.args
        if conn:
            conn.rollback()
        return jsonify({"error": f"Failed to delete patient: {error.message}"}), 400
    finally:
        if conn:
            conn.close()


@app.route('/api/donors/register', methods=['POST'])
def register_donor():
    data = request.json
    name = data.get('name')
    blood_group = data.get('blood_group')
    contact_number = data.get('contact_number')
    is_organ_donor = 1 if data.get('is_organ_donor') else 0

    if not all([name, blood_group, contact_number]):
        return jsonify({"error": "Missing required fields for donor registration."}), 400

    conn = None
    try:
        conn = get_db_connection()
        cursor = conn.cursor()

        # The Donor table uses auto-incrementing ID (IDENTITY)
        cursor.execute("""
            INSERT INTO Donor (name, blood_group, contact_number, is_organ_donor)
            VALUES (:name, :blood_group, :contact_number, :is_organ_donor)
        """, {'name': name, 'blood_group': blood_group, 'contact_number': contact_number, 'is_organ_donor': is_organ_donor})

        conn.commit()
        return jsonify({"message": f"Donor {name} registered successfully."})

    except ConnectionError:
        return jsonify({"error": "Database connection failed."}), 500
    except oracledb.DatabaseError as db_error:
        error, = db_error.args
        if conn:
            conn.rollback()
        return jsonify({"error": f"Donor Registration Failed: {error.message}"}), 400
    finally:
        if conn:
            conn.close()


@app.route('/api/patients', methods=['POST'])
def register_patient():
    data = request.json
    name = data.get('name')
    blood_group = data.get('blood_group')
    hospital = data.get('hospital')
    contact_number = data.get('contact_number')
    resource_needed = data.get('resource_needed')
    is_urgent = 1 if data.get('is_urgent') else 0

    if not all([name, blood_group, hospital, resource_needed]):
        return jsonify({"error": "Missing required fields for patient registration."}), 400

    conn = None
    try:
        conn = get_db_connection()
        cursor = conn.cursor()

        # Insert into Patient table
        cursor.execute("""
            INSERT INTO Patient (name, blood_group, hospital, contact_number, resource_needed, is_urgent)
            VALUES (:name, :blood_group, :hospital, :contact_number, :resource_needed, :is_urgent)
        """, {
            'name': name, 'blood_group': blood_group, 'hospital': hospital,
            'contact_number': contact_number, 'resource_needed': resource_needed, 'is_urgent': is_urgent
        })

        conn.commit()
        return jsonify({"message": f"Patient {name} registered successfully."})

    except ConnectionError:
        return jsonify({"error": "Database connection failed."}), 500
    except oracledb.DatabaseError as db_error:
        error, = db_error.args
        if conn:
            conn.rollback()
        return jsonify({"error": f"Patient Registration Failed: {error.message}"}), 400
    finally:
        if conn:
            conn.close()


@app.route('/api/donors/donate', methods=['POST'])
def record_blood_donation():
    data = request.json
    donor_id = data.get('donor_id')
    blood_group = data.get('blood_group')
    component = data.get('component')
    units = data.get('units')

    if not all([donor_id, blood_group, component, units]):
        return jsonify({"error": "Missing required fields for blood donation."}), 400

    conn = None
    try:
        conn = get_db_connection()
        cursor = conn.cursor()

        # Validate donor donation interval: must be >= 90 days since last donation
        try:
            cursor.execute("SELECT MAX(donation_date) FROM BloodDonationLog WHERE donor_id = :id", {'id': donor_id})
            row = cursor.fetchone()
            last_date = row[0] if row else None
            if last_date:
                # last_date is a datetime; compute difference
                now = datetime.datetime.now()
                # If last_date is naive or aware, keep logic simple: compare dates
                delta = now - last_date
                if delta.days < 90:
                    next_allowed = last_date + datetime.timedelta(days=90)
                    return jsonify({
                        "error": f"Donor ID {donor_id} last donated on {last_date.strftime('%Y-%m-%d')}. Next eligible on {next_allowed.strftime('%Y-%m-%d')} (90 day interval)."
                    }), 400
        except Exception:
            # If there's an issue checking history, continue — stored procedure will still validate further.
            pass

        # Call the stored procedure to handle the donation and stock update.
        # NOTE: The TRG_DONOR_INTERVAL check has been removed per request.
        cursor.callproc('SP_RECORD_BLOOD_DONATION', [donor_id, blood_group, units, component])

        conn.commit()
        return jsonify({"message": f"Blood donation recorded successfully for Donor ID {donor_id}."})

    except ConnectionError:
        return jsonify({"error": "Database connection failed."}), 500
    except oracledb.DatabaseError as db_error:
        error, = db_error.args
        if conn:
            conn.rollback()
        return jsonify({"error": f"Blood Donation Transaction Failed: {error.message}"}), 400
    except Exception as e:
        if conn:
            conn.rollback()
        return jsonify({"error": f"Failed to record blood donation: {e}"}), 400
    finally:
        if conn:
            conn.close()

@app.route('/api/blood/use', methods=['POST'])
def record_blood_usage():
    data = request.json
    patient_id = data.get('patient_id')
    blood_group = data.get('blood_group')
    component = data.get('component')
    units = data.get('units')

    if not all([patient_id, blood_group, component, units]):
        return jsonify({"error": "Missing required fields for blood usage."}), 400

    conn = None
    try:
        conn = get_db_connection()
        cursor = conn.cursor()

        # Call the stored procedure to handle the usage and stock decrement.
        cursor.callproc('SP_RECORD_BLOOD_USAGE', [patient_id, blood_group, component, units])

        conn.commit()
        return jsonify({"message": f"Blood usage recorded successfully for Patient ID {patient_id}."})

    except ConnectionError:
        return jsonify({"error": "Database connection failed."}), 500
    except oracledb.DatabaseError as db_error:
        error, = db_error.args
        if conn:
            conn.rollback()
        # Errors from SP_RECORD_BLOOD_USAGE (like insufficient stock) will be caught here
        return jsonify({"error": f"Blood Usage Transaction Failed: {error.message}"}), 400
    except Exception as e:
        if conn:
            conn.rollback()
        return jsonify({"error": f"Failed to record blood usage: {e}"}), 400
    finally:
        if conn:
            conn.close()


@app.route('/api/organ/donate', methods=['POST'])
def record_organ_donation():
    data = request.json
    donor_id = data.get('donor_id')
    organ_name = data.get('organ_name')

    if not all([donor_id, organ_name]):
        return jsonify({"error": "Missing required fields for organ donation."}), 400

    conn = None
    try:
        conn = get_db_connection()
        cursor = conn.cursor()

        # Check if donor has opted for organ donation
        cursor.execute("""
            SELECT is_organ_donor FROM Donor WHERE donor_id = :donor_id
        """, {'donor_id': donor_id})
        
        result = cursor.fetchone()
        if not result:
            return jsonify({"error": f"Donor ID {donor_id} not found."}), 404
        
        if result[0] != 1:
            return jsonify({"error": f"Donor ID {donor_id} has not opted for organ donation."}), 403

        # The schema uses a trigger (TRG_UPDATE_ORGAN_STOCK_ON_DONATION) to update the stock table
        cursor.execute("""
            INSERT INTO OrganDonationLog (donor_id, organ_name, donation_date, status)
            VALUES (:donor_id, :organ_name, SYSDATE, 'Available')
        """, {'donor_id': donor_id, 'organ_name': organ_name})

        conn.commit()
        return jsonify({"message": f"Organ donation of '{organ_name}' recorded successfully."})

    except ConnectionError:
        return jsonify({"error": "Database connection failed."}), 500
    except oracledb.DatabaseError as db_error:
        error, = db_error.args
        if conn:
            conn.rollback()
        return jsonify({"error": f"Organ Donation Transaction Failed: {error.message}"}), 400
    except Exception as e:
        if conn:
            conn.rollback()
        return jsonify({"error": f"Failed to record organ donation: {e}"}), 400
    finally:
        if conn:
            conn.close()

@app.route('/api/organ/use', methods=['POST'])
def record_organ_usage():
    data = request.json
    patient_id = data.get('patient_id')
    organ_name = data.get('organ_name')

    if not all([patient_id, organ_name]):
        return jsonify({"error": "Missing required fields for organ usage."}), 400

    conn = None
    try:
        conn = get_db_connection()
        cursor = conn.cursor()

        # 1. Update OrganStock (Decrement by 1)
        cursor.execute("""
            SELECT units_available FROM OrganStock WHERE organ_name = :organ_name FOR UPDATE
        """, {'organ_name': organ_name})

        current_stock = cursor.fetchone()

        if not current_stock or current_stock[0] < 1:
            raise ValueError(f"Insufficient or unknown organ stock for '{organ_name}'. Current stock: {current_stock[0] if current_stock else 0}")

        new_stock = current_stock[0] - 1

        # cursor.execute("""
        #     UPDATE OrganStock
        #     SET units_available = :new_stock,
        #         last_updated = SYSDATE
        #     WHERE organ_name = :organ_name
        # """, {'new_stock': new_stock, 'organ_name': organ_name})


        # 2. Record the usage in OrganUsageLog
        cursor.execute("""
            INSERT INTO ORGANUSAGELOG (organ_name, patient_id, usage_date)
            VALUES (:organ_name, :patient_id, SYSDATE)
        """, {'organ_name': organ_name, 'patient_id': patient_id})

        conn.commit()
        return jsonify({"message": f"Organ '{organ_name}' successfully used for Patient ID {patient_id}. Stock decremented and usage logged."})

    except ConnectionError:
        return jsonify({"error": "Database connection failed."}), 500
    except oracledb.DatabaseError as db_error:
        error, = db_error.args
        if conn:
            conn.rollback()
        return jsonify({"error": f"Organ Usage Transaction Failed: {error.message}"}), 400
    except Exception as e:
        if conn:
            conn.rollback()
        return jsonify({"error": f"Failed to record organ usage: {e}"}), 400
    finally:
        if conn:
            conn.close()


if __name__ == '__main__':
    # Initialize the Oracle client environment
    try:
        # This is recommended for Oracle client on certain OS environments
        # oracledb.init_oracle_client()
        app.run(debug=True)
    except oracledb.InterfaceError as e:
        print(f"FATAL ERROR: Oracle client setup failed. Ensure the Instant Client is installed and configured correctly. Error: {e}")
        # Optionally exit or continue with limited functionality
    except Exception as e:
        print(f"An unexpected error occurred during startup!: {e}")