package com.example.attendance_app // Make sure this matches your actual package name!

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import io.flutter.plugins.GeneratedPluginRegistrant 
import androidx.biometric.BiometricPrompt          // ✅ NEW
import androidx.biometric.BiometricManager
import androidx.core.content.ContextCompat  

@SuppressLint("MissingPermission")
class MainActivity: FlutterFragmentActivity() {
    private val METHOD_CHANNEL = "com.attendance/command"
    private val EVENT_CHANNEL = "com.attendance/events"

    // The two pipes we need for the Handshake
    private val CHAR_UUID_WRITE = UUID.fromString("11111111-2222-3333-4444-555555555555") // Client -> Host
    private val CHAR_UUID_ECHO = UUID.fromString("22222222-3333-4444-5555-666666666666")  // Host -> Client

    private var eventSink: EventChannel.EventSink? = null
    private var bluetoothGattServer: BluetoothGattServer? = null
    private var bluetoothManager: BluetoothManager? = null
    private var currentServiceUuid: UUID? = null


    
    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startServer" -> {
                    val uuidStr = call.argument<String>("uuid")
                    if (uuidStr != null) {
                        currentServiceUuid = UUID.fromString(uuidStr)
                        startBleServer(currentServiceUuid!!)
                        result.success("Server Initialization Command Sent to OS")
                    } else {
                        result.error("ERR", "UUID is required to start server", null)
                    }
                }
                "stopServer" -> {
                    stopBleServer()
                    result.success("Server Stopped")
                }
                "sendEcho" -> {
                    // NEW: Flutter calls this to push the 16-byte response back to the Scanner
                    val address = call.argument<String>("address")
                    val hexStr = call.argument<String>("payload")
                    
                    if (address != null && hexStr != null) {
                        val success = sendEchoToClient(address, hexStr)
                        if (success) result.success("Echo Pushed") else result.error("ERR", "Failed to send echo", null)
                    } else {
                        result.error("ERR", "Missing address or payload", null)
                    }
                }
            // ✅ NEW: Native biometric prompt — bypasses local_auth plugin activity bug
                "showBiometricPrompt" -> {
                    val executor = ContextCompat.getMainExecutor(this)
                    val biometricPrompt = BiometricPrompt(this, executor,
                        object : BiometricPrompt.AuthenticationCallback() {
                            override fun onAuthenticationSucceeded(
                                authResult: BiometricPrompt.AuthenticationResult
                            ) {
                                Handler(Looper.getMainLooper()).post {
                                    result.success("SUCCESS")
                                }
                            }
                            override fun onAuthenticationError(
                                errorCode: Int,
                                errString: CharSequence
                            ) {
                                Handler(Looper.getMainLooper()).post {
                                    result.error("AUTH_ERROR", errString.toString(), errorCode)
                                }
                            }
                            override fun onAuthenticationFailed() {
                                // Finger not recognized — prompt stays open, do nothing
                            }
                        }
                    )
                    val promptInfo = BiometricPrompt.PromptInfo.Builder()
                        .setTitle("Reset Biometric Key")
                        .setDescription("Scan fingerprint to lock Keystore to current biometrics")
                        .setNegativeButtonText("Cancel")
                        .build()
                    biometricPrompt.authenticate(promptInfo)
                }
                // ✅ END NEW
                
                "isBiometricAvailable" -> {
                    val biometricManager = BiometricManager.from(this)
                    // ✅ FIX: Accept both STRONG and WEAK fingerprint scanners
                    val canAuthenticate = biometricManager.canAuthenticate(
                        BiometricManager.Authenticators.BIOMETRIC_STRONG or 
                        BiometricManager.Authenticators.BIOMETRIC_WEAK
                    )
                    
                    if (canAuthenticate == BiometricManager.BIOMETRIC_SUCCESS) {
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }

                "checkBiometricKey" -> {
                    try {
                        val keyStore = java.security.KeyStore.getInstance("AndroidKeyStore")
                        keyStore.load(null)
                        
                        if (!keyStore.containsAlias("attendance_credentials")) {
                            // ✅ FIX: Throw an error instead of returning a success string!
                            result.error("KEY_MISSING", "Key was never created", null)
                            return@setMethodCallHandler
                        }
                        
                        val privateKey = keyStore.getKey("attendance_credentials", null)
                        val signature = java.security.Signature.getInstance("SHA256withECDSA")
                        signature.initSign(privateKey as java.security.PrivateKey)
                        
                        result.success("KEY_VALID")
                    } catch (e: java.security.InvalidKeyException) {
                        result.error("KEY_INVALIDATED", "Biometric enrollment changed", null)
                    } catch (e: Exception) {
                        result.error("KEY_ERR", e.message, null)
                    }
                }

                "resetBiometricKey" -> {
    try {
        // Step 1: Delete old key from Android Keystore
        val keyStore = java.security.KeyStore.getInstance("AndroidKeyStore")
        keyStore.load(null)
        if (keyStore.containsAlias("attendance_credentials")) {
            keyStore.deleteEntry("attendance_credentials")
            android.util.Log.d("BiometricReset", "Old key deleted from Keystore.")
        }

        // Step 2: Generate new key pair bound to current biometrics
        // This key will be PERMANENTLY INVALIDATED if user adds/removes fingerprints
        val keyPairGenerator = java.security.KeyPairGenerator.getInstance(
            android.security.keystore.KeyProperties.KEY_ALGORITHM_EC,
            "AndroidKeyStore"
        )
        val keyGenParameterSpec = android.security.keystore.KeyGenParameterSpec.Builder(
            "attendance_credentials",
            android.security.keystore.KeyProperties.PURPOSE_SIGN or
            android.security.keystore.KeyProperties.PURPOSE_VERIFY
        )
            .setDigests(android.security.keystore.KeyProperties.DIGEST_SHA256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true) // 🔑 THIS is what detects new fingerprints
            .build()

        keyPairGenerator.initialize(keyGenParameterSpec)
        keyPairGenerator.generateKeyPair()

        android.util.Log.d("BiometricReset", "New biometric-bound key generated.")
        result.success("SUCCESS")
    } catch (e: Exception) {
        android.util.Log.e("BiometricReset", "Key reset failed: ${e.message}")
        result.error("KEY_ERR", e.message, null)
    }
}
                "writeKeystoreMarker" -> {
    try {
        val prefs = getSharedPreferences("attendance_keystore", MODE_PRIVATE)
        prefs.edit().putString("key_marker", "keystore_bound_v1").apply()
        result.success("WRITTEN")
    } catch (e: Exception) {
        result.error("WRITE_ERR", e.message, null)
    }
}

                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            }
        )
    }

    private fun startBleServer(serviceUuid: UUID) {
        bluetoothManager = getSystemService(BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = bluetoothManager?.adapter

        if (adapter == null || !adapter.isMultipleAdvertisementSupported) {
            Handler(Looper.getMainLooper()).post {
                eventSink?.success("FATAL:HARDWARE: FEATURE_UNSUPPORTED. Phone cannot host GATT.")
            }
            return
        }
        
        bluetoothGattServer = bluetoothManager?.openGattServer(this, gattServerCallback)
        
        val service = BluetoothGattService(serviceUuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        
        // 1. Write Pipe (Scanner sends the AES Challenge here)
        val writeChar = BluetoothGattCharacteristic(CHAR_UUID_WRITE, 
            BluetoothGattCharacteristic.PROPERTY_WRITE, 
            BluetoothGattCharacteristic.PERMISSION_WRITE)
            
        // 2. Notify Pipe (Host pushes the AES Echo back here)
        val echoChar = BluetoothGattCharacteristic(CHAR_UUID_ECHO, 
            BluetoothGattCharacteristic.PROPERTY_NOTIFY or BluetoothGattCharacteristic.PROPERTY_READ, 
            BluetoothGattCharacteristic.PERMISSION_READ)

        val cccd = BluetoothGattDescriptor(
        UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"),
        BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
        )   
        echoChar.addDescriptor(cccd)
        
        service.addCharacteristic(writeChar)
        service.addCharacteristic(echoChar)
        bluetoothGattServer?.addService(service)

        val advertiser = adapter.bluetoothLeAdvertiser
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .build()
            
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(serviceUuid))
            .build()
        
        advertiser?.startAdvertising(settings, data, object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                super.onStartSuccess(settingsInEffect)
                Handler(Looper.getMainLooper()).post {
                    eventSink?.success("LOG: OS confirmed broadcast is active on hardware.")
                }
            }

            override fun onStartFailure(errorCode: Int) {
                super.onStartFailure(errorCode)
                Handler(Looper.getMainLooper()).post {
                    eventSink?.success("FATAL:HARDWARE: Error Code $errorCode")
                }
            }
        })
    }

    private fun stopBleServer() {
        bluetoothGattServer?.clearServices()
        bluetoothGattServer?.close()
    }

    // --- NEW: Function to push data back to the Scanner ---
    private fun sendEchoToClient(deviceAddress: String, hexPayload: String): Boolean {
        try {
            // Convert Hex String back to Byte Array
            val bytes = hexPayload.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
            
            val device = bluetoothManager?.adapter?.getRemoteDevice(deviceAddress)
            val service = currentServiceUuid?.let { bluetoothGattServer?.getService(it) }
            val echoChar = service?.getCharacteristic(CHAR_UUID_ECHO)

            if (device != null && echoChar != null) {
                echoChar.value = bytes
                bluetoothGattServer?.notifyCharacteristicChanged(device, echoChar, false)
                return true
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return false
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        
        // Handle Client Subscribing to Echo updates
        override fun onDescriptorWriteRequest(device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor, preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray) {
            if (responseNeeded) {
                bluetoothGattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }

        // Handle Incoming Challenge
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            super.onCharacteristicWriteRequest(device, requestId, characteristic, preparedWrite, responseNeeded, offset, value)
            
            // 1. INSTANT ACKNOWLEDGEMENT (This is what stops the Scanner's RTT Stopwatch)
            if (responseNeeded) {
                bluetoothGattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            }

            if (characteristic.uuid == CHAR_UUID_WRITE) {
                // 2. Convert raw AES bytes to Hex String to pass over the platform channel safely
                val hexString = value.joinToString("") { "%02X".format(it) }
                val macAddress = device.address

                Handler(Looper.getMainLooper()).post {
                    // Send to Flutter format: "CHALLENGE:[MAC_ADDRESS]:[HEX_PAYLOAD]"
                    eventSink?.success("CHALLENGE:$macAddress:$hexString")
                }
            }
        }
    }
}