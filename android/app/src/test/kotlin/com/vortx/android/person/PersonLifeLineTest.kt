package com.vortx.android.person

import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PersonLifeLineTest {
    private fun detail(born: String? = null, died: String? = null, place: String? = null, pretty: String? = null) =
        PersonDetail(name = "X", biography = null, birthday = pretty, placeOfBirth = place, profileUrl = null,
            knownForDepartment = null, birthdayIso = born, deathdayIso = died)

    @Test fun `living person shows age and birthplace`() {
        val line = PersonLifeLine.describe(detail("1996-09-01", place = "Oakland, California, USA"), LocalDate.of(2026, 10, 13))!!
        assertTrue(line, line.startsWith("Born "))
        assertTrue(line, line.contains("(age 30)"))
        assertTrue(line, line.endsWith("in Oakland, California, USA"))
    }

    @Test fun `age is not reached before the birthday`() {
        assertEquals(29, PersonLifeLine.years(LocalDate.of(1996, 9, 1), LocalDate.of(2026, 8, 31)))
    }

    @Test fun `a person who died shows their age at death and no current age`() {
        val line = PersonLifeLine.describe(detail("1950-01-10", "2017-03-05"), LocalDate.of(2026, 10, 13))!!
        assertTrue(line, line.contains("(aged 67)"))
        assertTrue(line, !line.contains("(age "))
    }

    @Test fun `missing data falls back cleanly`() {
        assertNull(PersonLifeLine.describe(detail()))
        assertNull(PersonLifeLine.describe(null))
        assertEquals("Born Mar 1, 1970", PersonLifeLine.describe(detail(pretty = "Mar 1, 1970")))
        assertEquals("London", PersonLifeLine.describe(detail(place = "London")))
    }
}
