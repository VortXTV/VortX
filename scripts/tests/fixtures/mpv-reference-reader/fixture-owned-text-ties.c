/* Source-only genuine constructor/text fixture. UNCOMPILED/UNRUN.
 * Link one fresh actual dec_sub.c plus genuine converter/libass dependencies.
 * global must be the real initialized idle client's mpv_global retained through
 * every decoder call and destruction. No VO, player/account, HTTP or model.
 * The earlier 74-case receipt is historical and is not replayed/relabeled.
 */
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include "mpv_talloc.h"
#include "osdep/timer.h"
#include "sub/dec_sub.h"

static bool text_has(struct dec_sub *sub, double seconds, const char *needle)
{
    char *text = sub_get_text(sub, seconds, SD_TEXT_TYPE_PLAIN);
    bool found = text && strstr(text, needle);
    talloc_free(text);
    return found;
}

static void tie_check(bool ok, const char *name, unsigned *checks, unsigned *failures)
{
    (*checks)++;
    *failures += !ok;
    printf("%s owned-text-ties %s\n", ok ? "PASS" : "FAIL", name);
    fflush(stdout);
}

int fixture_owned_text_ties(struct mpv_global *global,
                          unsigned *checks, unsigned *failures)
{
    if (!global || !checks || !failures)
        return 1;
    unsigned before = *failures;
    const struct sub_owned_text_cue cues[] = {
        {1000, 5000, "first-tie", sizeof("first-tie") - 1},
        {1000, 4000, "second-tie", sizeof("second-tie") - 1},
        {1000, 6000, "third-tie", sizeof("third-tie") - 1},
        {2000, 180000, "long-overlap", sizeof("long-overlap") - 1},
    };
    enum sub_owned_text_error error = SUB_OWNED_TEXT_INVALID_STATE;
    struct attachment_list *attachments = talloc_zero(NULL, struct attachment_list);
    struct dec_sub *sub = sub_create_owned_text(global, attachments, "eng", cues,
        sizeof(cues) / sizeof(cues[0]), 1, 25, NULL,
        mp_time_ns() + SUB_OWNED_TEXT_MAX_WORK_NS, &error);
    tie_check(sub && error == SUB_OWNED_TEXT_OK, "same-start complete corpus constructed",
              checks, failures);
    if (sub) {
        tie_check(text_has(sub, 1.5, "first-tie") &&
                  text_has(sub, 1.5, "second-tie") &&
                  text_has(sub, 1.5, "third-tie") &&
                  !text_has(sub, 1.5, "long-overlap"),
                  "all three equal-start occurrences survive real SubRip-to-ASS",
                  checks, failures);
        tie_check(text_has(sub, 4.5, "first-tie") &&
                  !text_has(sub, 4.5, "second-tie") &&
                  text_has(sub, 4.5, "third-tie") &&
                  text_has(sub, 4.5, "long-overlap"),
                  "equal starts retain independent ends and overlap", checks, failures);
        tie_check(!text_has(sub, 5.5, "first-tie") &&
                  !text_has(sub, 5.5, "second-tie") &&
                  text_has(sub, 5.5, "third-tie") &&
                  text_has(sub, 5.5, "long-overlap"),
                  "remaining equal-start and long cue stay intact", checks, failures);
        tie_check(text_has(sub, 150.0, "long-overlap") &&
                  !text_has(sub, 180.5, "long-overlap"),
                  "valid cue over 120 seconds has its real end", checks, failures);
        tie_check(text_has(sub, 1.5, "first-tie") &&
                  text_has(sub, 1.5, "second-tie") &&
                  text_has(sub, 1.5, "third-tie"),
                  "backward query retains all predecoded equal-start occurrences",
                  checks, failures);
        sub_destroy_owned_text(sub);
    }

    const struct sub_owned_text_cue backwards[] = {
        {2000, 4000, "later", sizeof("later") - 1},
        {1000, 3000, "earlier", sizeof("earlier") - 1},
    };
    error = SUB_OWNED_TEXT_OK;
    sub = sub_create_owned_text(global,
        talloc_zero(NULL, struct attachment_list), "eng", backwards, 2,
        1, 25, NULL, mp_time_ns() + SUB_OWNED_TEXT_MAX_WORK_NS, &error);
    tie_check(!sub && error == SUB_OWNED_TEXT_INVALID_INPUT,
              "descending starts still reject the whole constructor request", checks, failures);
    if (sub)
        sub_destroy_owned_text(sub);
    return *failures != before;
}
