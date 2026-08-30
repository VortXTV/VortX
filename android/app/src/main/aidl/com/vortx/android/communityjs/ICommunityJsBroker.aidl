package com.vortx.android.communityjs;

import com.vortx.android.communityjs.ICommunityJsBrokerCallback;

interface ICommunityJsBroker {
    void execute(String token, String code, String tmdbId, String mediaType, String settingsJson,
                 int season, int episode, long timeoutMs, long memoryLimitBytes,
                 ICommunityJsBrokerCallback callback);
    oneway void cancel(String token);
}
