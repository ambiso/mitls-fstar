let _ = Callback.register "MITLS_FFI_Config" FFI.ffiConfig;
        Callback.register "MITLS_FFI_SetTicketKey" FFI.ffiSetTicketKey;
        Callback.register "MITLS_FFI_SetSealingKey" FFI.ffiSetSealingKey;
        Callback.register "MITLS_FFI_SetCipherSuites" FFI.ffiSetCipherSuites;
        Callback.register "MITLS_FFI_SetSignatureAlgorithms" FFI.ffiSetSignatureAlgorithms;
        Callback.register "MITLS_FFI_SetNamedGroups" FFI.ffiSetNamedGroups;
        Callback.register "MITLS_FFI_SetALPN" FFI.ffiSetALPN;
        Callback.register "MITLS_FFI_SetEarlyData" FFI.ffiSetEarlyData;
        Callback.register "MITLS_FFI_SetTicketCallback" FFI.ffiSetTicketCallback;
        Callback.register "MITLS_FFI_SetCertCallbacks" FFI.ffiSetCertCallbacks;
        Callback.register "MITLS_FFI_Connect"  FFI.ffiConnect;
        Callback.register "MITLS_FFI_AcceptConnected"  FFI.ffiAcceptConnected;
        Callback.register "MITLS_FFI_Send" FFI.ffiSend;
        Callback.register "MITLS_FFI_Recv" FFI.ffiRecv;
        Callback.register "MITLS_FFI_GetExporter" FFI.ffiGetExporter;
        Callback.register "MITLS_FFI_GetCert" FFI.ffiGetCert;
        Callback.register "MITLS_FFI_QuicConfig" QUIC.ffiConfig;
        (* Deprecated QUIC API
        Callback.register "MITLS_FFI_QuicCreateClient" QUIC.ffiConnect;
        Callback.register "MITLS_FFI_QuicCreateServer" QUIC.ffiAcceptConnected;
        Callback.register "MITLS_FFI_QuicProcess" QUIC.recv;
        *)
        (* Callback.register "MITLS_FFI_TicketCallback" FFI.ffiTicketCallback;
        Callback.register "MITLS_FFI_CertSelectCallback" FFI.ffiCertSelectCallback;
        Callback.register "MITLS_FFI_CertFormatCallback" FFI.ffiCertFormatCallback;
        Callback.register "MITLS_FFI_CertSignCallback" FFI.ffiCertSignCallback;
        Callback.register "MITLS_FFI_CertVerifyCallback" FFI.ffiCertVerifyCallback; *)
