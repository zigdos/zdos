/* Port hooks included by extmod/modtime.c when calendar conversions are on. */
#include "py/mperrno.h"
#include "shared/timeutils/timeutils.h"
#include "zdos.h"

// Read ZDOS's local wall clock for time.localtime() / time.gmtime() without
// an explicit timestamp. ZDOS does not expose a timezone or UTC offset.
static void mp_time_localtime_get(timeutils_struct_time_t *tm) {
    if (zdos == NULL || zdos->time->get == NULL) {
        mp_raise_OSError(MP_ENODEV);
    }

    zdos_time now;
    zdos->time->get(&now);
    if (now.year < 1 || now.month < 1 || now.month > 12 || now.day < 1
        || now.day > timeutils_days_in_month(now.year, now.month)
        || now.hour > 23 || now.minute > 59 || now.second > 59) {
        mp_raise_OSError(MP_EIO);
    }

    tm->tm_year = now.year;
    tm->tm_mon = now.month;
    tm->tm_mday = now.day;
    tm->tm_hour = now.hour;
    tm->tm_min = now.minute;
    tm->tm_sec = now.second;
    tm->tm_wday = timeutils_calc_weekday(tm->tm_year, tm->tm_mon, tm->tm_mday);
    tm->tm_yday = timeutils_year_day(tm->tm_year, tm->tm_mon, tm->tm_mday);
}
