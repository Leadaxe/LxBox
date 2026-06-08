/// Тернарный mode (radio) поверх пары полей
/// `entry.{useDetourServers, overrideDetour}`. Mapping:
///   use      → useDetour=true,  override=''
///   override → useDetour=true,  override=`'<tag>'`
///   none     → useDetour=false, override=''
enum DetourMode { use, override, none }
