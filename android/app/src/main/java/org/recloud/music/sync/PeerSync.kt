package org.recloud.music.sync

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.*
import java.net.*
import java.security.*
import java.security.cert.X509Certificate
import javax.net.ssl.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.recloud.music.data.*
import org.recloud.music.repository.Collection

data class Peer(val name: String, val service: NsdServiceInfo)

data class PairState(
    val status: String = "",
    val code: String = "",
    val peers: List<Peer> = emptyList(),
    val active: Boolean = false,
)

internal fun DataInputStream.packet(): LibraryPacket {
    val size = readInt()
    require(size in 1..8_388_608) { "Library exceeds the sync size limit." }
    return codec.decodeFromString(ByteArray(size).also { readFully(it) }.toString(Charsets.UTF_8))
}

internal fun DataOutputStream.packet(value: LibraryPacket) {
    val bytes = codec.encodeToString(value).toByteArray()
    require(bytes.size in 1..8_388_608) { "Library exceeds the sync size limit." }
    writeInt(bytes.size)
    write(bytes)
    flush()
}

private const val TYPE = "_recloud-lib._tcp."
private const val PROTOCOL = "ReCloud/1"
private const val ALIAS = "recloud-sync-tls"

private fun tls(): SSLContext {
    val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    if (!keys.containsAlias(ALIAS)) {
        KeyPairGenerator.getInstance("EC", "AndroidKeyStore")
            .apply {
                initialize(
                    KeyGenParameterSpec.Builder(
                            ALIAS,
                            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
                        )
                        .setAlgorithmParameterSpec(
                            java.security.spec.ECGenParameterSpec("secp256r1")
                        )
                        .setDigests(
                            // Conscrypt supplies the handshake digest to NONEwithECDSA on older
                            // Android.
                            KeyProperties.DIGEST_NONE,
                            KeyProperties.DIGEST_SHA256,
                            KeyProperties.DIGEST_SHA384,
                            KeyProperties.DIGEST_SHA512,
                        )
                        .build()
                )
            }
            .generateKeyPair()
    }
    val cert = keys.getCertificate(ALIAS) as X509Certificate
    val manager =
        object : X509KeyManager {
            override fun chooseClientAlias(
                types: Array<out String>?,
                issuers: Array<out Principal>?,
                socket: Socket?,
            ) = ALIAS

            override fun chooseServerAlias(
                type: String?,
                issuers: Array<out Principal>?,
                socket: Socket?,
            ) = if (type == "EC") ALIAS else null

            override fun getClientAliases(type: String?, issuers: Array<out Principal>?) =
                arrayOf(ALIAS)

            override fun getServerAliases(type: String?, issuers: Array<out Principal>?) =
                arrayOf(ALIAS)

            override fun getCertificateChain(alias: String?) = arrayOf(cert)

            override fun getPrivateKey(alias: String?) = keys.getKey(ALIAS, null) as PrivateKey
        }
    // The user authenticates both TLS certificates by comparing the displayed digest before any
    // library data is sent.
    val pairingTrust =
        object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>, authType: String) {
                require(chain.size == 1)
                chain[0].checkValidity()
            }

            override fun checkServerTrusted(chain: Array<out X509Certificate>, authType: String) =
                checkClientTrusted(chain, authType)

            override fun getAcceptedIssuers() = emptyArray<X509Certificate>()
        }
    return SSLContext.getInstance("TLSv1.2").apply {
        init(arrayOf(manager), arrayOf(pairingTrust), SecureRandom())
    }
}

@Suppress("DEPRECATION")
class PeerSync(ctx: Context, private val store: Collection) : Closeable {
    val state = MutableStateFlow(PairState())
    private val nsd = ctx.getSystemService(NsdManager::class.java)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var generation = 0
    @Volatile private var server: SSLServerSocket? = null
    @Volatile private var socket: SSLSocket? = null
    private var registration: NsdManager.RegistrationListener? = null
    private var discovery: NsdManager.DiscoveryListener? = null
    private var job: Job? = null
    private var confirmation = CompletableDeferred<Boolean>()

    fun host() {
        stop()
        val current = generation
        state.value = PairState("Starting a secure connection…", active = true)
        job =
            scope.launch {
                try {
                    val factory = withContext(Dispatchers.IO) { tls() }
                    val listener =
                        factory.serverSocketFactory.createServerSocket(0) as SSLServerSocket
                    server = listener
                    listener.needClientAuth = true
                    listener.soTimeout = 120000
                    val callbacks =
                        object : NsdManager.RegistrationListener {
                            override fun onServiceRegistered(info: NsdServiceInfo) {
                                if (current == generation)
                                    state.value =
                                        PairState(
                                            "Choose ${info.serviceName} on the other phone.",
                                            active = true,
                                        )
                            }

                            override fun onRegistrationFailed(info: NsdServiceInfo, error: Int) {
                                if (current == generation)
                                    stop("Could not advertise this phone ($error).")
                            }

                            override fun onServiceUnregistered(info: NsdServiceInfo) {}

                            override fun onUnregistrationFailed(info: NsdServiceInfo, error: Int) {}
                        }
                    registration = callbacks
                    nsd.registerService(
                        NsdServiceInfo().apply {
                            serviceType = TYPE
                            serviceName = "ReCloud " + android.os.Build.MODEL
                            port = listener.localPort
                        },
                        NsdManager.PROTOCOL_DNS_SD,
                        callbacks,
                    )
                    withContext(Dispatchers.IO) {
                        (listener.accept() as SSLSocket).use { exchange(it, true) }
                    }
                    stop("Libraries synchronized.")
                } catch (e: Exception) {
                    if (current == generation) stop(e.message ?: "Pairing ended.")
                }
            }
    }

    fun discover() {
        stop()
        val current = generation
        state.value =
            PairState("Searching for a hosting phone on this Wi-Fi network…", active = true)
        val callbacks =
            object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(type: String) {}

                override fun onDiscoveryStopped(type: String) {}

                override fun onStopDiscoveryFailed(type: String, error: Int) {}

                override fun onStartDiscoveryFailed(type: String, error: Int) {
                    if (current == generation) stop("Discovery failed ($error).")
                }

                override fun onServiceFound(info: NsdServiceInfo) {
                    if (current == generation)
                        state.value =
                            state.value.copy(
                                peers =
                                    (state.value.peers + Peer(info.serviceName, info)).distinctBy {
                                        it.name
                                    }
                            )
                }

                override fun onServiceLost(info: NsdServiceInfo) {
                    if (current == generation)
                        state.value =
                            state.value.copy(
                                peers = state.value.peers.filter { it.name != info.serviceName }
                            )
                }
            }
        discovery = callbacks
        runCatching { nsd.discoverServices(TYPE, NsdManager.PROTOCOL_DNS_SD, callbacks) }
            .onFailure { stop("Nearby network access is unavailable.") }
    }

    fun join(peer: Peer) {
        stop()
        val current = generation
        state.value = PairState("Connecting to ${peer.name}…", active = true)
        nsd.resolveService(
            peer.service,
            object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, error: Int) {
                    if (current == generation) stop("Could not resolve this phone ($error).")
                }

                override fun onServiceResolved(info: NsdServiceInfo) {
                    if (current != generation) return
                    job =
                        scope.launch {
                            try {
                                withContext(Dispatchers.IO) {
                                    (tls().socketFactory.createSocket() as SSLSocket).use {
                                        socket = it
                                        it.connect(InetSocketAddress(info.host, info.port), 10000)
                                        exchange(it, false)
                                    }
                                }
                                stop("Libraries synchronized.")
                            } catch (e: Exception) {
                                if (current == generation) stop(e.message ?: "Connection failed.")
                            }
                        }
                }
            },
        )
    }

    private suspend fun exchange(connection: SSLSocket, host: Boolean) {
        socket = connection
        connection.soTimeout = 90000
        connection.startHandshake()
        val session = connection.session
        val local = session.localCertificates.first().encoded
        val other = session.peerCertificates.first().encoded
        val fingerprint =
            MessageDigest.getInstance("SHA-256")
                .digest(if (host) local + other else other + local)
                .take(10)
                .joinToString("") { "%02X".format(it) }
                .chunked(4)
                .joinToString(" ")
        val input = DataInputStream(connection.inputStream)
        val output = DataOutputStream(connection.outputStream)
        output.writeUTF(PROTOCOL)
        output.flush()
        require(input.readUTF() == PROTOCOL) { "Incompatible library protocol." }
        state.value =
            PairState(
                "Compare all five groups on both phones, then confirm.",
                fingerprint,
                active = true,
            )
        require(withTimeout(85000) { confirmation.await() })
        output.writeBoolean(true)
        output.flush()
        require(input.readBoolean()) { "Peer declined pairing." }
        val localPacket = store.snapshot()
        val incoming =
            if (host) {
                val p = input.packet()
                output.packet(localPacket)
                p
            } else {
                output.packet(localPacket)
                input.packet()
            }
        store.merge(incoming)
        output.writeBoolean(true)
        output.flush()
        require(input.readBoolean())
    }

    fun confirm() {
        confirmation.complete(true)
    }

    fun stop(status: String = "") {
        generation++
        confirmation.cancel()
        confirmation = CompletableDeferred()
        job?.cancel()
        job = null
        runCatching { server?.close() }
        server = null
        runCatching { socket?.close() }
        socket = null
        registration?.let { runCatching { nsd.unregisterService(it) } }
        registration = null
        discovery?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        discovery = null
        state.value = PairState(status)
    }

    override fun close() {
        stop()
        scope.cancel()
    }
}
