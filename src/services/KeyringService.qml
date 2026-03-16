import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/Providers.js" as Providers

Item {
    id: root

    // --- Input (set by parent) ---
    property string provider: "ollama"

    // --- Keyring state ---
    property var _keyringCache: ({})
    property bool _keyringAvailable: false
    property bool _keyringLookupPending: false
    property bool _keyringLookupDeferred: false
    property string _keyringLookupProvider: ""
    property string _keyringStoreKey: ""
    property string _keyringStoreProvider: ""

    // --- Public API ---

    function resolveApiKey(prov) {
        var info = Providers.getProviderInfo(prov);
        if (!info.envVar) return "";
        var cached = _keyringCache[prov];
        if (cached && cached.length > 0) return cached;
        return Quickshell.env(info.envVar) || "";
    }

    function hasApiKeyForProvider(prov) {
        var info = Providers.getProviderInfo(prov);
        if (!info.envVar) return true;
        var cached = _keyringCache[prov];
        if (cached && cached.length > 0) return true;
        return (Quickshell.env(info.envVar) || "").length > 0;
    }

    function apiKeySource(prov) {
        var info = Providers.getProviderInfo(prov);
        if (!info.envVar) return "";
        var cached = _keyringCache[prov];
        if (cached && cached.length > 0) return "keyring";
        if ((Quickshell.env(info.envVar) || "").length > 0) return "env";
        return "";
    }

    function checkSecretToolAvailable() {
        secretToolCheck.running = true;
    }

    function refreshKeyringKey() {
        if (!_keyringAvailable) return;
        if (provider === "ollama") return;
        if (keyringLookup.running) {
            _keyringLookupDeferred = true;
            return;
        }
        var info = Providers.getProviderInfo(provider);
        if (!info.envVar) return;
        _keyringLookupProvider = provider;
        keyringLookup.command = ["secret-tool", "lookup", "service", "ephemera", "provider", provider];
        _keyringLookupPending = true;
        keyringLookup.running = true;
    }

    function storeKeyringKey(prov, key) {
        if (!_keyringAvailable || !key) return;
        if (keyringStore.running) return;
        var safeKey = Providers.sanitizeApiKey(key);
        if (!safeKey) return;
        var cache = _cloneCache();
        cache[prov] = safeKey;
        _keyringCache = cache;
        _keyringStoreKey = safeKey;
        _keyringStoreProvider = prov;
        var info = Providers.getProviderInfo(prov);
        var label = "Ephemera " + (info.name || prov) + " API key";
        keyringStore.command = ["secret-tool", "store", "--label=" + label, "service", "ephemera", "provider", prov];
        keyringStore.stdinEnabled = true;
        keyringStore.running = true;
    }

    function clearKeyringKey(prov) {
        if (!_keyringAvailable) return;
        if (keyringClear.running) return;
        var cache = _cloneCache();
        delete cache[prov];
        _keyringCache = cache;
        keyringClear.command = ["secret-tool", "clear", "service", "ephemera", "provider", prov];
        keyringClear.running = true;
    }

    // --- Internal ---

    // Always return a new object so QML property var change detection fires.
    function _cloneCache() {
        var c = {};
        var old = _keyringCache;
        for (var k in old) c[k] = old[k];
        return c;
    }

    // --- Processes ---

    Process {
        id: secretToolCheck
        running: false
        command: ["which", "secret-tool"]
        onExited: exitCode => {
            root._keyringAvailable = (exitCode === 0);
            if (root._keyringAvailable)
                root.refreshKeyringKey();
        }
    }

    Process {
        id: keyringLookup
        running: false
        stdout: StdioCollector {
            id: keyringLookupCollector
            onStreamFinished: {
                var key = Providers.sanitizeApiKey(text);
                if (key.length > 0) {
                    var cache = root._cloneCache();
                    cache[root._keyringLookupProvider] = key;
                    root._keyringCache = cache;
                }
            }
        }
        onExited: exitCode => {
            root._keyringLookupPending = false;
            if (root._keyringLookupDeferred) {
                root._keyringLookupDeferred = false;
                root.refreshKeyringKey();
            }
        }
    }

    Process {
        id: keyringStore
        running: false
        stdinEnabled: true
        onRunningChanged: {
            if (running && root._keyringStoreKey) {
                keyringStore.write(root._keyringStoreKey);
                keyringStore.stdinEnabled = false;
                root._keyringStoreKey = "";
            }
        }
        onExited: exitCode => {
            if (exitCode !== 0 && root._keyringStoreProvider) {
                var cache = root._cloneCache();
                delete cache[root._keyringStoreProvider];
                root._keyringCache = cache;
            }
            root._keyringStoreProvider = "";
        }
    }

    Process {
        id: keyringClear
        running: false
    }
}
