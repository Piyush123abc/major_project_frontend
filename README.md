# Rapid, Proximity-Bound Aggregation of Identities over Unreliable Wireless Channels
**A high-security, decentralized attendance system using BLE GATT pipelines and Django.**



## 🚨 The Problem with Existing Systems
Every current attendance system is fundamentally flawed:
* **Manual Roll Call:** Wastes 20–30% of teaching time and is trivially defeated by proxying.
* **Face Recognition/Biometrics:** Creates massive physical bottlenecks at the door and requires expensive hardware.
* **RFID Cards:** Verifies the card, not the student (easily handed to friends).
* **Basic BLE Beacons:** Passive signals can be easily spoofed or forwarded over the internet.

## 💡 Our Solution: The Self-Organizing Connection Graph
Instead of a central scanner, our system validates presence through a distributed network of **Peer-to-Peer (P2P) Handshakes**. 

As students scan dynamic QR codes, their phones ignore the "noise" of 50 nearby devices and lock onto a specific peer via Bluetooth Low Energy (BLE). This initiates an automatic cryptographic handshake, extending the "Connection Graph" until the entire room is linked together like a giant net.

---

## 🏗️ Core Architecture & Security Layers

### 1. The Master Node & BST Validation
The Professor’s phone acts as the authorized "Root" (Master Node). The backend processes the connection tree using a Binary Search Tree (BST) or Graph-based logic. If the system can trace a path from your phone back to the Master Node through the backend's tree, you are officially in the room. No connection to the Master Node means no attendance.

### 2. Device Anchoring & Biometric Gates
Before a QR code is even generated, the system checks two things:
1. **Hardware Locking:** The app cross-references the current device against a cryptographically anchored hardware signature (UUID/IMEI) stored at registration.
2. **Android Keystore:** A fingerprint scan is required. If a student tries to add a friend's fingerprint to their phone settings, the Android Keystore detects the tampering and locks the token generation.

### 3. Google Play Integrity API (Anti-Tamper)
To prevent a "modified client attack" (where a student reverse-engineers the app to remove proximity checks), the Django backend verifies the app with Google before distributing session keys. This ensures the app is from the official Play Store, unmodified, and running on a genuine, non-rooted device.

---

## 🔐 The BLE GATT Handshake Protocol
To prevent relay, repeat, and spoofing attacks, we utilize a strict 3-step GATT handshake bounded by Round Trip Time (RTT) limits.

**Step 1: Student sends encrypted challenge**
The student computes `token = HMAC-SHA256(session_seed, n)` and encrypts it along with their UUID using `AES-128-GCM(K1)`. The payload is written to the GATT Characteristic, and the **RTT Timer starts**.

**Step 2: Server (Faculty/Peer) echoes identity stamp**
The receiving server decrypts the payload. The server *cannot* verify the token (it lacks the `session_seed`), but it echoes the token back alongside its own `server_UUID` and the `session_id`, encrypted again via `AES-128-GCM`.

**Step 3: Multi-Factor Integrity Verification**
The student receives the echo, stops the **RTT Timer**, and performs three simultaneous checks:

* **Check 1 (Anti-Relay): Is RTT < 150ms?**
  * *Pass:* Device is physically close (BLE takes ~2ms).
  * *Fail:* Internet relays add 50-200ms. Abort.
* **Check 2 (Anti-Spoof): Does `server_UUID` match the registered faculty/peer?**
  * *Pass:* Genuine server confirmed.
  * *Fail:* Fake GATT server detected. Abort.
* **Check 3 (Anti-Replay): Does the echoed token match `HMAC(session_seed, n)`?**
  * *Pass:* Packet integrity and freshness confirmed.
  * *Fail:* Stale nonce detected. Abort.

*(If all 3 pass: Counter `n` increments, handshake is VERIFIED, and confirmation is sent to Django).*

---

## 📡 RSSI Proximity Verification
As a secondary layer to the RTT timer, the system reads the RSSI (Received Signal Strength Indicator) immediately after the handshake. This prevents students sitting in hallways from connecting to the mesh.

| Distance | Typical RSSI | Meaning |
| :--- | :--- | :--- |
| **0 - 1 metre** | `-40` to `-55 dBm` | Same desk, very close |
| **1 - 3 metres** | `-55` to `-70 dBm` | Normal classroom neighbour |
| **3 - 5 metres** | `-70` to `-80 dBm` | Getting far, borderline |
| **Outside room** | `-80` to `-95 dBm` | Through wall, too far. **(Rejected)** |
| **No signal** | below `-95 dBm` | Definitely not present |

---

## 🛡️ Fallback & Exception Protocols
* **Simplified Fallback Mode:** For older Android hardware that struggles with GATT servers, the system falls back to a BLE Mesh + QR + Encrypted Token + GPS radius verification.
* **Delegate Master Node:** If the faculty's phone dies, they can promote a verified student's phone to act as the temporary "Proxy Root".
* **Human-Assisted Bypass:** If a student's phone is dead, a verified peer can flag them for review. At the end of class, the professor sees a visual audit list to approve with one tap.

## 🛠 Tech Stack
* **Frontend:** Flutter, Dart, `flutter_blue_plus`, `encrypt`
* **Backend:** Django, Python, SQLite/PostgreSQL
* **Security:** Google Play Integrity API, AES-128-GCM, HMAC-SHA256
