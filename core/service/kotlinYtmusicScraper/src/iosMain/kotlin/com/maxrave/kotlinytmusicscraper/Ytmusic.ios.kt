package com.maxrave.kotlinytmusicscraper

import platform.Foundation.NSLocale
import platform.Foundation.countryCode
import platform.Foundation.currentLocale
import platform.Foundation.languageCode

// These were swapped (country returned the language and vice versa), so YouTube received
// gl=pt / hl=BR and rejected every browse request with 400 INVALID_ARGUMENT.
actual fun getCountry(): String = NSLocale.currentLocale.countryCode ?: "US"

actual fun getLanguage(): String = NSLocale.currentLocale.languageCode
