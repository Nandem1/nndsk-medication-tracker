package cl.nndsk.medication.core

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class EffectiveTimeTest {
    @Test fun repeatedSantiagoTimeRequiresAnExplicitInstant() {
        assertEquals(2, effectiveOffsets("2026-04-04", "23:30", "America/Santiago").size)
        assertEquals(Instant.parse("2026-04-05T02:30:00Z"), effectiveInstant("2026-04-04", "23:30", "America/Santiago", "-03:00"))
        assertEquals(Instant.parse("2026-04-05T03:30:00Z"), effectiveInstant("2026-04-04", "23:30", "America/Santiago", "-04:00"))
    }
    @Test(expected = IllegalArgumentException::class) fun ambiguityIsNeverResolvedSilently() { effectiveInstant("2026-04-04", "23:30", "America/Santiago", null) }
    @Test(expected = IllegalArgumentException::class) fun nonexistentTimeIsRejected() { effectiveInstant("2026-09-06", "00:30", "America/Santiago", null) }
}
