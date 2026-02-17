package  expo.modules.onebox.oneoh.cloud.aidl;

import  expo.modules.onebox.oneoh.cloud.aidl.IServiceCallback;

interface IService {
    int getStatus();
    void registerCallback(in IServiceCallback callback);
    oneway void unregisterCallback(in IServiceCallback callback);
}
