package com.yandex.div.internal.util

import android.content.Context
import android.content.ContextWrapper
import androidx.lifecycle.LifecycleOwner
import java.lang.ref.WeakReference
import kotlin.properties.ReadWriteProperty
import kotlin.reflect.KProperty

internal inline fun <T> MutableCollection<T>.removeFirstIf(predicate: (T) -> Boolean): Boolean {
    val iterator = iterator()
    while (iterator.hasNext()) {
        if (predicate(iterator.next())) {
            iterator.remove()
            return true
        }
    }
    return false
}

internal fun <K, V> MutableMap<out K, V>.removeOrThrow(key: K, message: String? = null): V {
    return remove(key) ?: throw NoSuchElementException(message)
}

internal fun <K, V> Map<out K, V>.getOrThrow(key: K, message: String? = null): V {
    return get(key) ?: throw NoSuchElementException(message)
}

/**
 * Usage:
 *
 * val/var myWeakRef by weak(myStrongRef)
 */

internal fun <T> weak(obj: T? = null): ReadWriteProperty<Any?, T?> = WeakRef(obj)

private class WeakRef<T>(obj: T? = null) : ReadWriteProperty<Any?, T?> {

    private var weakReference: WeakReference<T>?

    init {
        this.weakReference = obj?.let { WeakReference(it) }
    }

    override fun getValue(thisRef: Any?, property: KProperty<*>): T? {
        return weakReference?.get()
    }

    override fun setValue(thisRef: Any?, property: KProperty<*>, value: T?) {
        weakReference = value?.let { WeakReference(it) }
    }
}

internal fun Context.tryGetLifecycleOwner(): LifecycleOwner? {
    if (this is LifecycleOwner) return this

    return (this as? ContextWrapper)?.baseContext?.tryGetLifecycleOwner()
}
