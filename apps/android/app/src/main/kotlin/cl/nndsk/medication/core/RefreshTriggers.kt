package cl.nndsk.medication.core

internal class RefreshTriggers<Network>(private var network: Network?) {
    private var resumed = false
    @Synchronized fun resumed(): Boolean = resumed.also { resumed = true }
    @Synchronized fun available(value: Network): Boolean = (network != value).also { network = value }
    @Synchronized fun lost(value: Network) { if (network == value) network = null }
}
