# Прототип нативного редактора конфига (sora-editor + TextMate).
# jcodings/joni ищут кодировки и таблицы по имени класса, tm4e — модели
# грамматик/тем через рефлексию; R8 их переименовывает, clinit падает с NPE.
-keep class org.jcodings.** { *; }
-keep class org.joni.** { *; }
-keep class org.eclipse.tm4e.** { *; }
-keep class io.github.rosemoe.sora.** { *; }
-dontwarn org.jcodings.**
-dontwarn org.joni.**
-dontwarn org.eclipse.tm4e.**
# keep на sora тянет ShareableData$DefaultImpls.clone → kotlin.Cloneable$DefaultImpls (нет в рантайме).
-dontwarn kotlin.Cloneable$DefaultImpls
