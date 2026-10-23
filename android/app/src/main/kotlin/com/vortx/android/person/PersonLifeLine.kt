package com.vortx.android.person

import java.time.LocalDate
import java.time.Period
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * "Born 1 September 1996 (age 30) in Oakland, California, USA", or "Born … · Died … (aged 67)", assembled
 * from whichever parts TMDB returned. Pure, so the age arithmetic is testable. Mirrors Apple `PersonLifeLine`.
 */
internal object PersonLifeLine {
    fun describe(detail: PersonDetail?, today: LocalDate = LocalDate.now()): String? {
        detail ?: return null
        val born = parse(detail.birthdayIso)
        val died = parse(detail.deathdayIso)
        val birth = buildList {
            when {
                born != null -> add(buildString {
                    append("Born ${display(born)}")
                    if (died == null) years(born, today)?.let { append(" (age $it)") }
                })
                detail.birthday != null -> add("Born ${detail.birthday}")
            }
            detail.placeOfBirth?.let { add(if (isEmpty()) it else "in $it") }
        }
        val parts = buildList {
            if (birth.isNotEmpty()) add(birth.joinToString(" "))
            died?.let { date ->
                add(buildString {
                    append("Died ${display(date)}")
                    if (born != null) years(born, date)?.let { append(" (aged $it)") }
                })
            }
        }
        return parts.takeIf { it.isNotEmpty() }?.joinToString("  ·  ")
    }

    fun years(start: LocalDate, end: LocalDate): Int? =
        if (end.isBefore(start)) null else Period.between(start, end).years

    private fun parse(iso: String?): LocalDate? =
        iso?.takeIf { it.length == 10 }?.let { runCatching { LocalDate.parse(it) }.getOrNull() }

    private fun display(date: LocalDate): String =
        date.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.LONG))
}
