# Keep crash reports readable: without this, stack traces from a shrunk build
# point at obfuscated names and line numbers are dropped.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# XmlPullParserFactory.newInstance() resolves its implementation reflectively,
# so R8 cannot see the link from our code to the parser it actually uses.
# On Android these classes come from the platform, but keep them explicitly so
# the channel-list and device-info parsers cannot be shrunk out from under us.
-keep class org.xmlpull.v1.** { *; }
-dontwarn org.xmlpull.v1.**

# The service is bound through this Binder subclass and cast back on the other
# side; keep it whole so the cast in MainActivity cannot break.
-keep class com.home.rokuremote.RemoteService$LocalBinder { *; }

# Started by the system from the manifest with no direct code reference.
-keep class com.home.rokuremote.BootReceiver { *; }
