package  expo.modules.onebox.oneoh.cloud.aidl;

interface IServiceCallback {
    void onServiceStatusChanged(int status);
    void onServiceAlert(int type, String message);
}
