package com.vortx.android.communityjs;

interface ICommunityJsBrokerCallback {
    String fetch(String token, String url, String optionsJson, long remainingTimeoutMs);
    boolean isCancelled(String token);
    void complete(String token, String envelope);
}
