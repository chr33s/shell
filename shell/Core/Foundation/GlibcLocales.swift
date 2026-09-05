//
//  GlibcLocales.swift
//
//  Locale data derived from glibc's localedata/SUPPORTED file — the set of
//  locales that can exist on a Linux server. iOS freely pairs any language
//  with any region (e.g. English + Mexico = en_MX), but glibc only ships
//  data for specific combinations; sending an unknown pair makes every
//  login spam "setlocale: cannot change locale" errors.
//
//  Regenerate from glibc HEAD:
//    curl -s "https://sourceware.org/git/?p=glibc.git;a=blob_plain;f=localedata/SUPPORTED;hb=HEAD" \
//      | grep -oE '^[a-z]{2,3}_[A-Z]{2,3}' | sort -u
//

import Foundation

enum GlibcLocales: Sendable {

    /// Every language_REGION pair glibc ships locale data for.
    nonisolated static let supportedPairs: Set<String> = [
        "aa_DJ", "aa_ER", "aa_ET", "af_ZA", "agr_PE", "ak_GH", "am_ET", "an_ES",
        "anp_IN", "ar_AE", "ar_BH", "ar_DZ", "ar_EG", "ar_IN", "ar_IQ", "ar_JO",
        "ar_KW", "ar_LB", "ar_LY", "ar_MA", "ar_OM", "ar_QA", "ar_SA", "ar_SD",
        "ar_SS", "ar_SY", "ar_TN", "ar_YE", "as_IN", "ast_ES", "ayc_PE", "az_AZ",
        "az_IR", "be_BY", "bem_ZM", "ber_DZ", "ber_MA", "bg_BG", "bhb_IN", "bho_IN",
        "bho_NP", "bi_VU", "bn_BD", "bn_IN", "bo_CN", "bo_IN", "br_FR", "brh_PK",
        "brx_IN", "bs_BA", "byn_ER", "ca_AD", "ca_ES", "ca_FR", "ca_IT", "ce_RU",
        "chr_US", "ckb_IQ", "cmn_TW", "crh_RU", "crh_UA", "cs_CZ", "csb_PL", "cv_RU",
        "cy_GB", "da_DK", "de_AT", "de_BE", "de_CH", "de_DE", "de_IT", "de_LI",
        "de_LU", "doi_IN", "dsb_DE", "dv_MV", "dz_BT", "el_CY", "el_GR", "en_AG",
        "en_AU", "en_BW", "en_CA", "en_DK", "en_GB", "en_HK", "en_IE", "en_IL",
        "en_IN", "en_NG", "en_NZ", "en_PH", "en_SC", "en_SE", "en_SG", "en_US",
        "en_ZA", "en_ZM", "en_ZW", "es_AR", "es_BO", "es_CL", "es_CO", "es_CR",
        "es_CU", "es_DO", "es_EC", "es_ES", "es_GT", "es_HN", "es_MX", "es_NI",
        "es_PA", "es_PE", "es_PR", "es_PY", "es_SV", "es_US", "es_UY", "es_VE",
        "et_EE", "eu_ES", "fa_IR", "ff_SN", "fi_FI", "fil_PH", "fo_FO", "fr_BE",
        "fr_CA", "fr_CH", "fr_FR", "fr_LU", "fur_IT", "fy_DE", "fy_NL", "ga_IE",
        "gbm_IN", "gd_GB", "gez_ER", "gez_ET", "gl_ES", "gu_IN", "gv_GB", "ha_NG",
        "hak_TW", "he_IL", "hi_IN", "hif_FJ", "hne_IN", "hr_HR", "hrx_BR", "hsb_DE",
        "ht_HT", "hu_HU", "hy_AM", "ia_FR", "id_ID", "ig_NG", "ik_CA", "is_IS",
        "it_CH", "it_IT", "iu_CA", "ja_JP", "ka_GE", "kab_DZ", "kk_KZ", "kl_GL",
        "km_KH", "kn_IN", "ko_KR", "kok_IN", "ks_IN", "ku_TR", "kv_RU", "kw_GB",
        "ky_KG", "lb_LU", "lg_UG", "li_BE", "li_NL", "lij_IT", "ln_CD", "lo_LA",
        "lt_LT", "ltg_LV", "lv_LV", "lzh_TW", "mag_IN", "mai_IN", "mai_NP", "mdf_RU",
        "mfe_MU", "mg_MG", "mhr_RU", "mi_NZ", "miq_NI", "mjw_IN", "mk_MK", "ml_IN",
        "mn_MN", "mni_IN", "mnw_MM", "mr_IN", "ms_MY", "mt_MT", "my_MM", "nan_TW",
        "nb_NO", "nds_DE", "nds_NL", "ne_NP", "nhn_MX", "niu_NU", "niu_NZ", "nl_AW",
        "nl_BE", "nl_NL", "nn_NO", "nr_ZA", "nso_ZA", "oc_FR", "om_ET", "om_KE",
        "or_IN", "os_RU", "pa_IN", "pa_PK", "pap_AW", "pap_CW", "pl_PL", "ps_AF",
        "pt_BR", "pt_PT", "quz_PE", "raj_IN", "rif_MA", "ro_RO", "ru_RU", "ru_UA",
        "rw_RW", "sa_IN", "sah_RU", "sat_IN", "sc_IT", "scn_IT", "sd_IN", "se_NO",
        "sgs_LT", "shn_MM", "shs_CA", "si_LK", "sid_ET", "sk_SK", "sl_SI", "sm_WS",
        "so_DJ", "so_ET", "so_KE", "so_SO", "sq_AL", "sq_MK", "sr_ME", "sr_RS",
        "ss_ZA", "ssy_ER", "st_ZA", "su_ID", "sv_FI", "sv_SE", "sw_KE", "sw_TZ",
        "szl_PL", "ta_IN", "ta_LK", "tcy_IN", "te_IN", "tg_TJ", "th_TH", "the_NP",
        "ti_ER", "ti_ET", "tig_ER", "tk_TM", "tl_PH", "tn_ZA", "to_TO", "tpi_PG",
        "tr_CY", "tr_TR", "ts_ZA", "tt_RU", "ug_CN", "uk_UA", "unm_US", "ur_IN",
        "ur_PK", "uz_UZ", "ve_ZA", "vi_VN", "wa_BE", "wae_CH", "wal_ET", "wo_SN",
        "xh_ZA", "yi_US", "yo_NG", "yue_HK", "yuw_PG", "zgh_MA", "zh_CN", "zh_HK",
        "zh_SG", "zh_TW", "zu_ZA",
    ]

    /// Locales glibc ships without a region component (Esperanto, Syriac, Toki Pona).
    nonisolated static let languageOnly: Set<String> = ["eo", "syr", "tok"]

    /// Script-variant locales glibc ships as @modifier forms of a base pair,
    /// keyed by "pair-Script" since modifier names are pair-specific (Latin
    /// Tatar is @iqtelif, not @latin). Currency modifiers (@euro) and
    /// non-script variants (@valencia, @abegede) are deliberately excluded.
    nonisolated static let scriptModifier: [String: String] = [
        "be_BY-Latn": "latin",
        "ks_IN-Deva": "devanagari",
        "nan_TW-Latn": "latin",
        "sd_IN-Deva": "devanagari",
        "sr_RS-Latn": "latin",
        "tt_RU-Latn": "iqtelif",
        "uz_UZ-Cyrl": "cyrillic",
    ]

    /// CLDR macro-region tags mapped to a concrete glibc pair. iOS offers
    /// "Spanish (Latin America)" as es-419; glibc has no es_419, and the
    /// mechanical fallback would pick European es_ES — the wrong variant —
    /// so route it to the largest Latin American Spanish locale instead.
    nonisolated static let macroRegionPairs: [String: String] = [
        "es_419": "es_MX",
    ]

    /// Regions that can express a given language+script combination:
    /// Simplified vs Traditional Chinese, Azerbaijani in Latin vs Arabic,
    /// Punjabi in Gurmukhi vs Shahmukhi, and Latin Serbian (which only
    /// exists as sr_RS@latin — sr_ME is Cyrillic despite Montenegro's
    /// Latin-leaning usage). Keyed by "lang-Script"; a requested region
    /// outside the list is replaced by the first one glibc supports.
    nonisolated static let scriptRegions: [String: [String]] = [
        "az-Arab": ["IR"],
        "az-Latn": ["AZ"],
        "pa-Arab": ["PK"],
        "pa-Guru": ["IN"],
        "sr-Cyrl": ["RS", "ME"],
        "sr-Latn": ["RS"],
        "zh-Hans": ["CN", "SG"],
        "zh-Hant": ["TW", "HK"],
    ]

    /// Preferred region for languages where the mechanical guess
    /// (language code uppercased, e.g. de_DE) has no glibc entry.
    /// Used when the device's language+region pair isn't a real locale.
    nonisolated static let defaultRegion: [String: String] = [
        "ar": "EG",
        "bn": "BD",
        "ca": "ES",
        "cs": "CZ",
        "da": "DK",
        "el": "GR",
        "en": "US",
        "et": "EE",
        "eu": "ES",
        "fa": "IR",
        "gl": "ES",
        "he": "IL",
        "hi": "IN",
        "ja": "JP",
        "ko": "KR",
        "ms": "MY",
        "nb": "NO",
        "nn": "NO",
        "sl": "SI",
        "sq": "AL",
        "sr": "RS",
        "sv": "SE",
        "uk": "UA",
        "ur": "PK",
        "vi": "VN",
        "zh": "CN",
    ]
}
