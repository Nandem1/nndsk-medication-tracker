package cl.nndsk.medication.notifications

import cl.nndsk.medication.core.wireJson
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class PushDeviceTest {
    @Test fun registrationIdentityIsStableAndSeparatedByAccount() {
        val first = pushDeviceID("installation-a", "synthetic-owner-a")
        assertEquals(first, pushDeviceID("installation-a", "synthetic-owner-a"))
        assertNotEquals(first, pushDeviceID("installation-a", "synthetic-owner-b"))
        assertNotEquals(first, pushDeviceID("installation-b", "synthetic-owner-a"))
        assertEquals(first, UUID.fromString(first).toString())
        assertFalse(first.contains("synthetic"))
    }
    @Test fun registrationDoesNotSendPatientOrTreatmentData() {
        val body = wireJson.parseToJsonElement(wireJson.encodeToString(PushDevice("synthetic-id", token = "synthetic-token", permission = "denied"))).jsonObject
        assertEquals(setOf("device_id", "platform", "token", "permission"), body.keys)
        assertEquals("fcm", body.getValue("platform").jsonPrimitive.content)
        assertEquals("denied", body.getValue("permission").jsonPrimitive.content)
    }
}
