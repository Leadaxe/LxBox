part of '../cc_channel.dart';

// -----------------------------------------------------------------------------
// Method-name константы — имена нативных методов `MethodChannel`, которые
// вызывает [CcChannel]. Строки те же, что были литералами в вызовах.
// -----------------------------------------------------------------------------

class _CcMethods {
  const _CcMethods._();

  static const ccCancelOpenConnectChallenge = 'ccCancelOpenConnectChallenge';
  static const ccCancelPing = 'ccCancelPing';
  static const ccCloseConnection = 'ccCloseConnection';
  static const ccCloseConnections = 'ccCloseConnections';
  static const ccConnectProfiler = 'ccConnectProfiler';
  static const ccConnectScreen = 'ccConnectScreen';
  static const ccDisconnectProfiler = 'ccDisconnectProfiler';
  static const ccDisconnectScreen = 'ccDisconnectScreen';
  static const ccGetDnsGroups = 'ccGetDnsGroups';
  static const ccGetGroups = 'ccGetGroups';
  static const ccGetOpenConnectStatus = 'ccGetOpenConnectStatus';
  static const ccGetOutbounds = 'ccGetOutbounds';
  static const ccGetImpairStatus = 'ccGetImpairStatus';
  static const ccGetPool = 'ccGetPool';
  static const ccGetRules = 'ccGetRules';
  static const ccGetRunningConfig = 'ccGetRunningConfig';
  static const ccGetEffectiveConfig = 'ccGetEffectiveConfig';
  static const ccGetOutboundConfig = 'ccGetOutboundConfig';
  static const ccGetTailscaleStatus = 'ccGetTailscaleStatus';
  static const ccGetUrlViaOutbound = 'ccGetUrlViaOutbound';
  static const ccGetWireGuardStatus = 'ccGetWireGuardStatus';
  static const ccScheduleImpair = 'ccScheduleImpair';
  static const ccSetImpair = 'ccSetImpair';
  static const ccPauseClients = 'ccPauseClients';
  static const ccResumeClients = 'ccResumeClients';
  static const ccResyncForReopen = 'ccResyncForReopen';
  static const ccSelectOutbound = 'ccSelectOutbound';
  static const ccSetEndpointEnabled = 'ccSetEndpointEnabled';
  static const ccSetStatusFast = 'ccSetStatusFast';
  static const ccSetTailscaleExitNode = 'ccSetTailscaleExitNode';
  static const ccStartConnectionTest = 'ccStartConnectionTest';
  static const ccStartOpenConnectCallback = 'ccStartOpenConnectCallback';
  static const ccStartTaildropInbox = 'ccStartTaildropInbox';
  static const ccStartTailscalePing = 'ccStartTailscalePing';
  static const ccStartTailscaleStatus = 'ccStartTailscaleStatus';
  static const ccStopConnectionTest = 'ccStopConnectionTest';
  static const ccStopOpenConnectCallback = 'ccStopOpenConnectCallback';
  static const ccStopTaildropInbox = 'ccStopTaildropInbox';
  static const ccStopTailscalePing = 'ccStopTailscalePing';
  static const ccStopTailscaleStatus = 'ccStopTailscaleStatus';
  static const ccSubmitOpenConnectForm = 'ccSubmitOpenConnectForm';
  static const ccTaildropCancelReceiving = 'ccTaildropCancelReceiving';
  static const ccTaildropDelete = 'ccTaildropDelete';
  static const ccTaildropInboxSnapshot = 'ccTaildropInboxSnapshot';
  static const ccTaildropMarkRead = 'ccTaildropMarkRead';
  static const ccTaildropPickAndSend = 'ccTaildropPickAndSend';
  static const ccTaildropSave = 'ccTaildropSave';
  static const ccTaildropSendBytes = 'ccTaildropSendBytes';
  static const ccTailscaleLogin = 'ccTailscaleLogin';
  static const ccTailscaleLogout = 'ccTailscaleLogout';
  static const ccTakeOpenConnectOpenRequest = 'ccTakeOpenConnectOpenRequest';
  static const ccTakeTaildropOpenRequest = 'ccTakeTaildropOpenRequest';
  static const ccUrlTestGroup = 'ccUrlTestGroup';
  static const ccUrlTestOutbound = 'ccUrlTestOutbound';
  static const probeCancel = 'probeCancel';
  static const probeGetUrl = 'probeGetUrl';
  static const probeStart = 'probeStart';
  static const probeStop = 'probeStop';
  static const probeUrlTest = 'probeUrlTest';
  static const taildropBuildServiceFile = 'taildropBuildServiceFile';
  static const taildropClipState = 'taildropClipState';
  static const taildropServiceStats = 'taildropServiceStats';
}
