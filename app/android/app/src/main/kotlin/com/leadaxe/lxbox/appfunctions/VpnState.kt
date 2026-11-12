package com.leadaxe.lxbox.appfunctions

import androidx.appfunctions.AppFunctionSerializable

/** The state of the L×Box VPN tunnel. */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class VpnState(
    /** The tunnel state: one of "stopped", "starting", "started" or "stopping". */
    val status: String,
)
