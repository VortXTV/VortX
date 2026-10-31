package android.content
// Storage boundary collaborator only; production one-field merge is extracted unchanged.
internal interface SharedPreferences {
    fun getString(key: String, fallback: String?): String? = fallback
    fun edit(): Editor = object : Editor {}
    interface Editor {
        fun putString(key: String, value: String): Editor = this
        fun commit(): Boolean = true
    }
}
