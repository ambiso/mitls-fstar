
//**********************************************************************************************************************************
//
//   Purpose: TLSTESTER OBJECT source code file
//
//   Project: Everest
//
//  Filename: TLSTester.cpp
//
//   Authors: Caroline.M.Mathieson (CMM)
//
//**********************************************************************************************************************************
//
//  Description
//  -----------
//
//! \file TLSTester.cpp
//! \brief Contains the complete implementation of the TLSTESTER Object. This covers TLS tester attributes and functions.
//!
//**********************************************************************************************************************************

#include "stdafx.h"
#include "process.h"

#include "InteropTester.h"
#include "Tester.h"

#include "mitlsffi.h" // this is the real interface!
#include "mipki.h"    // interface for the certificate handling

//**********************************************************************************************************************************

 // in simpleserver.cpp

extern int PrintSocketError ( void );

extern void DumpPacket ( void         *Packet,         // the packet to be hex dumped
                         unsigned int  PacketLength,   // the length of the packet in octets
                         unsigned int  HighlightStart, // the first octet of special interest
                         unsigned int  HighlightEnd,   // the last octet of special interest (0 = none)
                         const char   *Title );        // the purpose of the packet (if known)

//**********************************************************************************************************************************

// see https://github.com/project-everest/mitls-fstar/blob/e2490b839c46beac96c0900beee4d19111355b21/src/tls/FFI.fst#L244

static const int NumberOfCipherSuites = 14;

static const char *SupportedCipherSuites [ NumberOfCipherSuites ] =
{
    // these are the cipher suites offered by default in the ClientHello

    "TLS_AES_128_GCM_SHA256",
    "TLS_AES_256_GCM_SHA384",
    "TLS_CHACHA20_POLY1305_SHA256",
    "TLS_AES_128_CCM_SHA256",
    "TLS_AES_128_CCM_8_SHA256",
    "ECDHE-RSA-AES256-GCM-SHA384",
    "ECDHE-RSA-AES128-GCM-SHA256",
    "ECDHE-RSA-CHACHA20-POLY1305-SHA256",
    "ECDHE-ECDSA-AES256-GCM-SHA384",
    "ECDHE-ECDSA-AES128-GCM-SHA256",
    "ECDHE-ECDSA-CHACHA20-POLY1305-SHA256",
    "DHE-RSA-AES256-GCM-SHA384",
    "DHE-RSA-AES128-GCM-SHA256",
    "DHE-RSA-CHACHA20-POLY1305-SHA256",
};

//**********************************************************************************************************************************

// See https://github.com/project-everest/mitls-fstar/blob/master/src/tls/TLSConstants.fst and
// https://github.com/project-everest/mitls-fstar/blob/e2490b839c46beac96c0900beee4d19111355b21/src/tls/FFI.fst#L244

static const int NumberOfSignatureAlgorithms = 11;

static const char *SupportedSignatureAlgorithms [ NumberOfSignatureAlgorithms ] =
{
    "RSAPSS+SHA512",
    "RSAPSS+SHA384",
    "RSAPSS+SHA256",
    "RSA+SHA512",
    "RSA+SHA384",
    "RSA+SHA256",
    "RSA+SHA1",
    "ECDSA+SHA512",
    "ECDSA+SHA384",
    "ECDSA+SHA256",
    "ECDSA+SHA1",

    // these are the signature algorithms offered by default in the ClientHello Signature Algorithms Extension

    // legacy algorithms
//  "RSA_PKCS1_SHA1",    // no longer supported in kremlin code
//  "RSA_PKCS1_MD5SHA1", // only used internally for now
//  "ECDSA_SHA1",        // no longer supported in kremlin code

    // Not sure what these are (nothing in header file
//  "RSA_PKCS1_SHA256",
//  "RSA_PKCS1_SHA384",
//  "RSA_PKCS1_SHA512",

    // RSASSA-PSS Algorithms
//  "RSA_PSS_SHA256",
//  "RSA_PSS_SHA384",
//  "RSA_PSS_SHA512",

    // ECDSA Algorithms
//  "ECDSA_SECP256R1_SHA256:",
//  "ECDSA_SECP384R1_SHA384",
//  "ECDSA_SECP521R1_SHA512",

    // EDDSA Algorithms
//  "ED25519_SHA512",
//  "ED448_SHAKE256",

    // Reserved code points
//  "DSA_SHA1",
//  "DSA_SHA256",
//  "DSA_SHA384",
//  "DSA_SHA512",

    // old list
//  "ECDSA+SHA256",
//  "ECDSA+SHA384",
//  "ECDSA+SHA512",

};

//**********************************************************************************************************************************

// see https://github.com/project-everest/mitls-fstar/blob/master/src/tls/CommonDH.fst and
// https://github.com/project-everest/mitls-fstar/blob/e2490b839c46beac96c0900beee4d19111355b21/src/tls/FFI.fst#L244

static const int NumberOfNamedGroups = 8;

static const char *SupportedNamedGroups [ NumberOfNamedGroups ] =
{
    "P-521",
    "P-384",
    "P-256",
    "X25519",
    "X448",
    "FFDHE4096",
    "FFDHE3072",
    "FFDHE2048",
};

//**********************************************************************************************************************************

TLSTESTER::TLSTESTER (  FILE *DebugFile,
                        FILE *TestResultsFile,
                        FILE *RecordedMeasurementsFile ) :  TESTER ( DebugFile,
                                                                     TestResultsFile,
                                                                     RecordedMeasurementsFile )
{
    // set the default values here in case they are not over-ridden by command line arguments

    strcpy ( HostFileName, "\0" );

    NumberOfHostsRead = 0;

    memset ( HostNames, 0, sizeof ( HostNames ) );

    strcpy ( TLSVersion, "1.3" );

    strcpy ( HostName, "google.com" );

    PortNumber = 443;

    strcpy ( ClientCertificateFilename,    "server-ecdsa.crt" );
    strcpy ( ClientCertificateKeyFilename, "server-ecdsa.key" );
    strcpy ( ServerCertificateFilename,    "server-ecdsa.crt" );
    strcpy ( ServerCertificateKeyFilename, "server-ecdsa.key" );

    strcpy ( CertificateAuthorityChainFilename, "CAFile.pem" );

    // command line over-ride flags

    UseHostList = FALSE;

    UseHostName = FALSE;

    UsePortNumber = FALSE;

    DoTLSTests    = FALSE;
    DoQUICTests   = FALSE;
    DoClientTests = FALSE;
    DoServerTests = FALSE;

    DoDefaultTests     = FALSE;
    DoCombinationTests = FALSE;

    DoClientInteroperabilityTests = FALSE;
    DoServerInteroperabilityTests = FALSE;
}

//**********************************************************************************************************************************

void TLSTESTER::Configure ( void )
{
    Component = new COMPONENT ( this, DebugFile );

    // configure the component attributes using the command line arguments if any given or the defaults otherwise

    if ( Component != NULL )
    {
        Component->SetVersion  ( TLSVersion );

        Component->SetHostName ( HostName );

        Component->SetPortNumber ( PortNumber );

        Component->SetClientCertificateFilename ( ClientCertificateFilename );

        Component->SetClientCertificateKeyFilename ( ClientCertificateKeyFilename );

        Component->SetServerCertificateFilename ( ServerCertificateFilename );

        Component->SetServerCertificateKeyFilename ( ServerCertificateKeyFilename );

        // create the threads for the stdout redirection, client and server

        TerminatePipeThread   = FALSE;
        TerminateClientThread = FALSE;
        TerminateServerThread = FALSE;

        PipeThreadHandle = CreateThread ( NULL,                    // default security attributes
                                          0,                       // use default stack size
                                          PipeThread,              // thread function name
                                          this,                    // argument to thread function is class instance
                                          0,                       // use default creation flags
                                          &PipeThreadIdentifier ); // returns the thread identifier

        ClientThreadHandle = CreateThread ( NULL,                      // default security attributes
                                            0,                         // use default stack size
                                            PipeThread,                // thread function name
                                            this,                      // argument to thread function is class instance
                                            0,                         // use default creation flags
                                            &ClientThreadIdentifier ); // returns the thread identifier

        ServerThreadHandle = CreateThread ( NULL,                      // default security attributes
                                            0,                         // use default stack size
                                            PipeThread,                // thread function name
                                            this,                      // argument to thread function is class instance
                                            0,                         // use default creation flags
                                            &ServerThreadIdentifier ); // returns the thread identifier
    }

    _beginthread (   );
}

//**********************************************************************************************************************************

TLSTESTER::~TLSTESTER ( void )
{
    delete Component;
}

//**********************************************************************************************************************************

void TLSTESTER::RunClientTLSTests ( char *DateAndTimeString )
{
    int   MeasurementNumber        = 0;
    long  ExecutionTime            = 0;
    int   Result                   = 0;
    int   ErrorIndex               = 0;
    bool  Success                  = FALSE;

    RecordTestRunStartTime ( TLS_CLIENT_MEASUREMENTS );

    Component->SetTestRunNumber ( TLS_CLIENT_MEASUREMENTS );

    Result = Component->InitialiseTLS ();

    if ( ! Result ) { printf ( "Failed to Initialise TLS!\n" ); return; }

    Component->ConfigureTraceCallback ();

    ErrorIndex = Component->InitialisePKI ();

    if ( ErrorIndex != 0 ) { printf ( "Failed to Initialise PKI!\n" ); return; }

    if ( DoDefaultTests )
    {
        //
        // Run a measurement for just the default, cipher suite, signature algorithm and named group
        //

        QueryPerformanceCounter ( &MeasurementStartTime ); // just for this measurement to give a quick result below

        Success = RunSingleClientDefaultsTLSTest ( MeasurementNumber );

        QueryPerformanceCounter ( &MeasurementEndTime );

        if ( Success )
        {
            ExecutionTime = CalculateExecutionTime ( MeasurementStartTime, MeasurementEndTime );

            fprintf ( ComponentStatisticsFile,
                      "%s, %d, %s, Default, Default, Default, PASS, %u\n",
                      DateAndTimeString,
                      MeasurementNumber,
                      HostName,
                      ExecutionTime );
        }

        MeasurementNumber++;
    }

    if ( DoCombinationTests )
    {
        //
        // Then run a measurement for each combination of supported cipher suite, signature algorithm and named groups
        // for all specified hosts.
        //
        if ( UseHostList )
        {
            for ( int HostNumber = 0; HostNumber < NumberOfHostsRead; HostNumber++ )
            {
                Component->SetHostName ( HostNames [ HostNumber ] );

                MeasurementNumber = RunCombinationTest ( MeasurementNumber, DateAndTimeString, HostNames [ HostNumber ] );
            }
        }
        else
        {
            MeasurementNumber = RunCombinationTest ( MeasurementNumber, DateAndTimeString, HostName );
        }
    }

    Component->TerminatePKI ();

    Component->Cleanup ();

    RecordTestRunEndTime ( TLS_CLIENT_MEASUREMENTS );

    // add this set of tests to the total run

    Component->NumberOfMeasurementsMade += MeasurementNumber;
}

//**********************************************************************************************************************************

int TLSTESTER::RunCombinationTest ( int   MeasurementNumber,
                                    char *DateAndTimeString,
                                    char *HostName )
{
    int  CipherSuiteNumber        = 0;
    int  SignatureAlgorithmNumber = 0;
    int  NamedGroupNumber         = 0;
    int  Success                  = 0;
    long ExecutionTime            = 0;
    char *TestResult              = "FAIL"; // or "PASS"

    for ( CipherSuiteNumber = 0; CipherSuiteNumber < 1 /*NumberOfCipherSuites*/; CipherSuiteNumber++ )
    {
        for ( SignatureAlgorithmNumber = 0; SignatureAlgorithmNumber < 1 /*NumberOfSignatureAlgorithms*/; SignatureAlgorithmNumber++ )
        {
            for ( NamedGroupNumber = 0; NamedGroupNumber < 1 /*NumberOfNamedGroups*/; NamedGroupNumber++ )
            {
                QueryPerformanceCounter ( &MeasurementStartTime ); // just for this measurement to give a quick result below

                Success = RunSingleClientTLSTest ( MeasurementNumber,
                                                   SupportedCipherSuites        [ CipherSuiteNumber        ],
                                                   SupportedSignatureAlgorithms [ SignatureAlgorithmNumber ],
                                                   SupportedNamedGroups         [ NamedGroupNumber         ] );

                QueryPerformanceCounter ( &MeasurementEndTime );

                ExecutionTime = CalculateExecutionTime ( MeasurementStartTime, MeasurementEndTime );

                if ( Success ) TestResult = "PASS";

                fprintf ( ComponentStatisticsFile,
                          "%s, %d, %s, %s, %s, %s, %s, %u\n",
                          DateAndTimeString,
                          MeasurementNumber,
                          HostName,
                          SupportedCipherSuites        [ CipherSuiteNumber        ],
                          SupportedSignatureAlgorithms [ SignatureAlgorithmNumber ],
                          SupportedNamedGroups         [ NamedGroupNumber         ],
                          TestResult,
                          ExecutionTime );

                OperatorConfidence ();

                MeasurementNumber++;
            }
        }
    }

    return ( MeasurementNumber );
}

//**********************************************************************************************************************************

void TLSTESTER::RunServerTLSTests ( char * DateAndTimeString )
{
}

//**********************************************************************************************************************************

void TLSTESTER::RunClientQUICTests ( char * DateAndTimeString )
{
    int  CipherSuiteNumber        = 0;
    int  SignatureAlgorithmNumber = 0;
    int  NamedGroupNumber         = 0;
    int  MeasurementNumber        = 0;
    long ExecutionTime            = 0;
    int  Result                   = 0;
    int  ErrorIndex               = 0;

    RecordTestRunStartTime ( QUIC_CLIENT_MEASUREMENTS );

    Result = Component->InitialiseTLS ();

    if ( Result )
    {
        Component->ConfigureTraceCallback ();

        ErrorIndex = Component->InitialisePKI ();

        if ( ErrorIndex == 0 )
        {
            Result = Component->QuicCreate ();

            if ( Result )
            {
                //
                // run a measurement for each combination of cipher suite, algorithm and named group
                //

                for ( CipherSuiteNumber = 0; CipherSuiteNumber < NumberOfCipherSuites; CipherSuiteNumber++ )
                {
                    for ( SignatureAlgorithmNumber = 0; SignatureAlgorithmNumber < NumberOfSignatureAlgorithms; SignatureAlgorithmNumber++ )
                    {
                        for ( NamedGroupNumber = 0; NamedGroupNumber < NumberOfNamedGroups; NamedGroupNumber++ )
                        {
                            QueryPerformanceCounter ( &TestStartTime );

                            RunSingleClientQUICTest ( MeasurementNumber,
                                                      SupportedCipherSuites        [ CipherSuiteNumber        ],
                                                      SupportedSignatureAlgorithms [ SignatureAlgorithmNumber ],
                                                      SupportedNamedGroups         [ NamedGroupNumber         ] );

                            QueryPerformanceCounter ( &TestEndTime );

                            ExecutionTime = CalculateExecutionTime ( TestStartTime, TestEndTime );

                            fprintf ( ComponentStatisticsFile,
                                      "%s, %d, %s, %s, %s, %s, %u\n",
                                      DateAndTimeString,
                                      MeasurementNumber,
                                      SupportedCipherSuites        [ CipherSuiteNumber        ],
                                      SupportedSignatureAlgorithms [ SignatureAlgorithmNumber ],
                                      SupportedNamedGroups         [ NamedGroupNumber         ],
                                      "FAIL",
                                      ExecutionTime );

                            OperatorConfidence ();

                            MeasurementNumber++;
                        }
                    }
                }
            }
            else
            {
                printf ( "Component->QuicCreate() call failed!\n" );
            }

            Component->TerminatePKI ();
        }
        else
        {
            printf ( "Component->InitialisePKI() call failed with error %d!\n", ErrorIndex );
        }

        Component->Cleanup ();
    }
    else
    {
        printf ( "Component->InitialiseTLS() call failed!\n" );
    }

    RecordTestRunEndTime ( QUIC_CLIENT_MEASUREMENTS );

    // add this set of tests to the total run

    Component->NumberOfMeasurementsMade += MeasurementNumber;
}

//**********************************************************************************************************************************

void TLSTESTER::RunServerQUICTests ( char * DateAndTimeString )
{
}

//**********************************************************************************************************************************
//
// Client Interoperability TLS Tests
//
//**********************************************************************************************************************************

void TLSTESTER::RunOpenSSLClientTLSTests ( char * DateAndTimeString )
{
}

//**********************************************************************************************************************************

void TLSTESTER::RunBoringClientTLSTests ( char * DateAndTimeString )
{
}

//**********************************************************************************************************************************

void TLSTESTER::RunMbedTLSClientTLSTests ( char * DateAndTimeString )
{
}

//**********************************************************************************************************************************

void TLSTESTER::RunWolfSSLClientTLSTests ( char *DateAndTimeString )
{
}

//**********************************************************************************************************************************

void TLSTESTER::RunFizzClientTLSTests ( char *DateAndTimeString )
{
}

//**********************************************************************************************************************************
//
// Client Interoperability QUIC Tests
//
//**********************************************************************************************************************************

void TLSTESTER::RunOpenSSLClientQUICTests ( char * DateAndTimeString )
{
}

//**********************************************************************************************************************************

void TLSTESTER::RunBoringClientQUICTests ( char * DateAndTimeString )
{
}

//**********************************************************************************************************************************

void TLSTESTER::RunMbedTLSClientQUICTests ( char * DateAndTimeString )
{
}

//**********************************************************************************************************************************

void TLSTESTER::RunWolfSSLClientQUICTests ( char *DateAndTimeString )
{
}

//**********************************************************************************************************************************

void TLSTESTER::RunFizzClientQUICTests ( char *DateAndTimeString )
{
}

//**********************************************************************************************************************************
//
// Server Interoperability TLS Tests
//
//**********************************************************************************************************************************

void TLSTESTER::RunOpenSSLServerTLSTests ( char * DateAndTimeString )
{
}

//**********************************************************************************************************************************

void TLSTESTER::RunBoringServerTLSTests ( char * DateAndTimeString )
{
}

//**********************************************************************************************************************************

void TLSTESTER::RunMbedTLSServerTLSTests ( char * DateAndTimeString )
{
}

//**********************************************************************************************************************************

void TLSTESTER::RunWolfSSLServerTLSTests ( char *DateAndTimeString )
{
}

//**********************************************************************************************************************************

void TLSTESTER::RunFizzServerTLSTests ( char *DateAndTimeString )
{
}

//**********************************************************************************************************************************
//
// Server Interoperability QUIC Tests
//
//**********************************************************************************************************************************

void TLSTESTER::RunOpenSSLServerQUICTests ( char * DateAndTimeString )
{
}

//**********************************************************************************************************************************

void TLSTESTER::RunBoringServerQUICTests ( char * DateAndTimeString )
{
}

//**********************************************************************************************************************************

void TLSTESTER::RunMbedTLSServerQUICTests ( char * DateAndTimeString )
{
}

//**********************************************************************************************************************************

void TLSTESTER::RunWolfSSLServerQUICTests ( char *DateAndTimeString )
{
}

//**********************************************************************************************************************************

void TLSTESTER::RunFizzServerQUICTests ( char *DateAndTimeString )
{
}

//**********************************************************************************************************************************
//
// In a client test, only one socket is required, a socket for the connection to the peer (server) as the componenet uses send and
// receive callbacks to communicate with the environment. This makes the componenet platform and transport agnostic.
//
// <pre><code>
//                 ..
//    --------    .  .     ----------  Receive() -------------
//    |      |------------>|        |----------->|           |
//    | Peer |    .  .     | Tester |            | Component |
//    |      |<------------|        |<-----------|           |
//    --------    .  .     ----------   Send()   -------------
//                 ..
//                Peer
//               Socket
//
// </code></pre>
//
bool TLSTESTER::RunSingleClientTLSTest ( int         MeasurementNumber,
                                         const char *CipherSuite,
                                         const char *SignatureAlgorithm,
                                         const char *NamedGroup )
{
    struct hostent     *Peer;
    struct sockaddr_in  PeerAddress;
    int                 Response;
    int                 Result;
    bool                Success = FALSE;

    fprintf ( DebugFile,
              "Running single client TLS test %d on Cipher Suite %s, Signature Algorithm %s and Named group %s\n",
              MeasurementNumber,
              CipherSuite,
              SignatureAlgorithm,
              NamedGroup );

    if ( VerboseConsoleOutput )
    {
        printf ( "Running single client TLS test %d on Cipher Suite %s, Signature Algorithm %s and Named group %s\n",
                 MeasurementNumber,
                 CipherSuite,
                 SignatureAlgorithm,
                 NamedGroup );
    }

    // open socket to communicate with peer (server)

    PeerSocket = OpenPeerSocket ();

    if ( PeerSocket != INVALID_SOCKET )
    {
        Component->RecordStartTime (); // start time for this measurement

        Component->SetMeasurementNumber ( MeasurementNumber );

        Component->SetSocket ( PeerSocket ); // use the peer for now but switch to the server thread ASAP

        Result = Component->AddRootFileOrPath ( CertificateAuthorityChainFilename ); // must be done before the configure

        if ( Result )
        {
            Result = Component->Configure ();

            if ( Result )
            {
                Result = Component->ConfigureCipherSuites ( CipherSuite );

                if ( Result )
                {
                    Result = Component->ConfigureSignatureAlgorithms ( SignatureAlgorithm );

                    if ( Result )
                    {
                        Result = Component->ConfigureNamedGroups ( NamedGroup );

                        if ( Result )
                        {
                            Result = Component->ConfigureCertificateCallbacks ();

                            if ( Result )
                            {
                                Result = Component->ConfigureNegotiationCallback ();

                                if ( Result )
                                {
                                    Result = Component->Connect ();

                                    //
                                    // The component will call the send() and receive() callback functions to perform the handshake and the
                                    // Connect () function call returns only when the handshake is complete.
                                    //

                                    if ( Result )
                                    {
                                        if ( VerboseConsoleOutput ) printf ( "Component->Connect() was successful!\n" );

                                        Component->CloseConnection ();

                                        Success = TRUE;
                                    }
                                    else
                                    {
                                        printf ( "Component->Connect() failed!\n" );
                                    }
                                }
                                else
                                {
                                    printf ( "Component->ConfigureNegotiationCallback () failed!\n" );
                                }
                            }
                            else
                            {
                                printf ( "Component->ConfigureCertificateCallbacks() failed!\n" );
                            }
                        }
                        else
                        {
                            printf ( "Component->ConfigureNamedGroups ( %s ) failed!\n", NamedGroup );
                        }
                    }
                    else
                    {
                        printf ( "Component->ConfigureSignatureAlgorithms ( %s ) failed!\n", SignatureAlgorithm );
                    }
                }
                else
                {
                    printf ( "Component->ConfigureCipherSuites ( %s ) failed!\n", CipherSuite );
                }
            }
            else
            {
                printf ( "Component->Configure() failed!\n" );
            }
        }
        else
        {
            printf ( "Component->AddRootFileOrPath () failed!\n" );
        }

        Component->RecordEndTime ();

        if ( VerboseConsoleOutput ) printf ( "Last Error Code = %d\n", GetLastError () );

        closesocket ( PeerSocket );
    }

    return ( Success );
}

//**********************************************************************************************************************************

SOCKET TLSTESTER::OpenPeerSocket ( void )
{
    struct sockaddr_in   PeerAddress;
    struct hostent      *Peer        = NULL;
    int                  Response    = 0;
    SOCKET               PeerSocket  = INVALID_SOCKET;

    // open socket to communicate with peer (server)

    PeerSocket = socket ( AF_INET, SOCK_STREAM, 0 ); // we need a TCP socket as this is TLS!

    if ( PeerSocket != INVALID_SOCKET )
    {
        Peer = gethostbyname ( Component->GetHostName () );

        memset ( &PeerAddress, 0, sizeof ( PeerAddress ) );

        PeerAddress.sin_family = AF_INET;

        memcpy ( &PeerAddress.sin_addr.s_addr, Peer->h_addr, Peer->h_length );

        PeerAddress.sin_port = htons ( Component->GetPortNumber () );

        Response = connect ( PeerSocket, ( struct sockaddr* ) &PeerAddress, sizeof ( PeerAddress ) );

        if ( Response != 0 )
        {
            fprintf ( DebugFile, "Cannot connect to peer \"%s\" for test!\n", Component->GetHostName () );

            PrintSocketError ();

            closesocket ( PeerSocket ); // we can't use this socket so just close it

            PeerSocket = INVALID_SOCKET;
        }
    }
    else
    {
        fprintf ( DebugFile, "Cannot open TCP socket for peer!\n" );

        PrintSocketError ();
    }

    return ( PeerSocket );
}

//**********************************************************************************************************************************
//
// This test uses just the default configuration for the cipher suites, signature algorithms and named groups. The actual defaults
// could change from implementation to implementation as work progresses, so don't actually list them here.
//

bool TLSTESTER::RunSingleClientDefaultsTLSTest ( int MeasurementNumber )
{
    int    Response;
    int    Result;
    bool   Success    = FALSE;
    SOCKET PeerSocket = INVALID_SOCKET;

    fprintf ( DebugFile, "Running single client defaults TLS test %d\n", MeasurementNumber );

    if ( VerboseConsoleOutput )
    {
        printf ( "Running single client defaults TLS test %d\n", MeasurementNumber );
    }

    // open socket to communicate with peer (server)

    PeerSocket = OpenPeerSocket ();

    if ( PeerSocket != INVALID_SOCKET )
    {
        Component->RecordStartTime (); // start time for this measurement

        Component->SetMeasurementNumber ( MeasurementNumber );

        Component->SetSocket ( PeerSocket );

        Result = Component->AddRootFileOrPath ( CertificateAuthorityChainFilename ); // must be done before the configure

        if ( Result )
        {
            Result = Component->Configure (); // set default TLS version

            if ( Result )
            {
                Result = Component->ConfigureCertificateCallbacks ();

                if ( Result )
                {
                    Result = Component->ConfigureNegotiationCallback ();

                    if ( Result )
                    {
                        Result = Component->Connect ();

                        //
                        // The component will call the send() and receive() callback functions to perform the handshake and the
                        // Connect () function call returns only when the handshake is complete.
                        //

                        if ( Result )
                        {
                            if ( VerboseConsoleOutput ) printf ( "Component->Connect() was successful!\n" );

                            // don't do any data transfer in this particular test

                            Component->CloseConnection ();

                            Success = TRUE;
                        }
                        else
                        {
                            printf ( "Component->Connect() failed!\n" );
                        }
                    }
                    else
                    {
                        printf ( "Component->ConfigureNegotiationCallback () failed!\n" );
                    }
                }
                else
                {
                    printf ( "Component->ConfigureCertificateCallbacks () failed!\n" );
                }
            }
            else
            {
                printf ( "Component->Configure() failed!\n" );
            }
        }
        else
        {
            printf ( "Component->AddRootFileOrPath () failed!\n" );
        }

        Component->RecordEndTime ();

        if ( VerboseConsoleOutput ) printf ( "Last Error Code = %d\n", GetLastError () );
    }

    return ( Success );
}

//**********************************************************************************************************************************

void TLSTESTER::RunSingleServerTLSTest ( int         MeasurementNumber,
                                         const char *CipherSuite,
                                         const char *SignatureAlgorithm,
                                         const char *NamedGroup )
{
    fprintf ( DebugFile,
              "Running single server TLS test %d on Cipher Suite %s, Signature Algorithm %s and Named group %s\n",
              MeasurementNumber,
              CipherSuite,
              SignatureAlgorithm,
              NamedGroup );

    printf ( "Running single server TLS test %d on Cipher Suite %s, Signature Algorithm %s and Named group %s\n",
             MeasurementNumber,
             CipherSuite,
             SignatureAlgorithm,
             NamedGroup );
 }

//**********************************************************************************************************************************

const char *HashNames [] =
{
  "MD5",    // TLS_hash_MD5    = 0,
  "SHA1",   // TLS_hash_SHA1   = 1,
  "SHA224", // TLS_hash_SHA224 = 2,
  "SHA256", // TLS_hash_SHA256 = 3,
  "SHA384", // TLS_hash_SHA384 = 4,
  "SHA512", // TLS_hash_SHA512 = 5
};

const char *AEADNames [] =
{
    "AES_128_GCM",       // TLS_aead_AES_128_GCM       = 0,
    "AES_256_GCM",       // TLS_aead_AES_256_GCM       = 1,
    "CHACHA20_POLY1305", // TLS_aead_CHACHA20_POLY1305 = 2
};

size_t InputBufferSize  = 0;
size_t OutputBufferSize = 0;

unsigned char InputBuffer  [ 8192 ];
unsigned char OutputBuffer [ 8192 ];

void TLSTESTER::RunSingleClientQUICTest ( int         MeasurementNumber,
                                          const char *CipherSuite,
                                          const char *SignatureAlgorithm,
                                          const char *NamedGroup )
{
    struct hostent     *Peer;
    struct sockaddr_in  PeerAddress;
    int                 Response;
    int                 Result;
    int                 AmountSent;
    int                 AmountReceived;
    quic_result         QuicResult;
    quic_secret         EarlySecret;
    quic_secret         MainSecret;
    unsigned char       SecretBuffer [ ( sizeof ( EarlySecret.secret ) * 2 ) + 2 ];


    fprintf ( DebugFile,
              "Running single client QUIC test %d on Cipher Suite %s, Signature Algorithm %s and Named group %s\n",
              MeasurementNumber,
              CipherSuite,
              SignatureAlgorithm,
              NamedGroup );

    if ( VerboseConsoleOutput )
    {
        printf ( "Running single client QUIC test %d on Cipher Suite %s, Signature Algorithm %s and Named group %s\n",
                 MeasurementNumber,
                 CipherSuite,
                 SignatureAlgorithm,
                 NamedGroup );
    }

    // open socket to communicate with peer (server)

    PeerSocket = socket ( AF_INET, SOCK_STREAM, 0 ); // needs to be TCP as this is not a full implementation of QUIC!

    if ( PeerSocket != 0 )
    {
        Peer = gethostbyname ( Component->GetHostName () );

        memset ( &PeerAddress, 0, sizeof ( PeerAddress ) );

        PeerAddress.sin_family = AF_INET;

        memcpy ( &PeerAddress.sin_addr.s_addr, Peer->h_addr, Peer->h_length );

        PeerAddress.sin_port = htons ( Component->GetPortNumber () );

        Response = connect ( PeerSocket, ( struct sockaddr* ) &PeerAddress, sizeof ( PeerAddress ) );

        if ( Response == 0 )
        {
            Component->RecordStartTime ();

            Component->SetMeasurementNumber ( MeasurementNumber );

            Component->SetSocket ( PeerSocket ); // use the peer for now but switch to the server thread ASAP

            Result = Component->QuicCreate ();

            if ( Result )
            {
                //Result = Component->ConfigureCipherSuites ( CipherSuite );

                if ( Result )
                {
                    //Result = Component->ConfigureSignatureAlgorithms ( SignatureAlgorithm );

                    if ( Result )
                    {
                        //Result = Component->ConfigureNamedGroups ( NamedGroup );

                        if ( Result )
                        {
                            QuicResult = TLS_would_block;

                            while ( ( QuicResult != TLS_client_complete ) || ( QuicResult != TLS_client_complete_with_early_data ) )
                            {
                                // rather than using the send and receive callbacks, QUIC uses buffers

                                InputBufferSize = 0;

                                QuicResult = Component->QuicProcess ( InputBuffer,
                                                                      &InputBufferSize,
                                                                      OutputBuffer,
                                                                      &OutputBufferSize );

                                if ( ! PrintQuicResult ( QuicResult ) ); break; // stop if quic process returned an unknown result

                                // send any message to the peer

                                if ( OutputBufferSize != 0 )
                                {
                                    AmountSent = send ( PeerSocket, ( const char *) OutputBuffer, OutputBufferSize, 0 );

                                    if ( AmountSent != OutputBufferSize )
                                    {
                                        printf ( "network send() to peer failed!\n" ); PrintSocketError (); break;
                                    }
                                    else
                                    {
                                        DumpPacket ( OutputBuffer, OutputBufferSize, 0, 0, "sent to quic peer" );
                                    }
                                }

                                // receive any response from the peer

                                if ( InputBufferSize != 0 )
                                {
                                    AmountReceived = recv ( PeerSocket, (char *) InputBuffer, InputBufferSize, 0 );

                                    if ( AmountReceived != InputBufferSize )
                                    {
                                        printf ( "network recv() from peer failed!\n" ); PrintSocketError (); break;
                                    }
                                    else
                                    {
                                        DumpPacket ( InputBuffer, InputBufferSize, 0, 0, "received from quic peer" );
                                    }
                                }
                            }

                            // get any early secret and print it out

                            if ( Component->QuicGetExporter ( 0, &EarlySecret ) )
                            {
                                fprintf ( DebugFile,
                                          "EarlySecret: Hash = %d (%s), AEAD = %d (%s), Secret =",
                                          EarlySecret.hash,
                                          HashNames [ EarlySecret.hash ],
                                          EarlySecret.ae,
                                          AEADNames [ EarlySecret.ae ] );

                                for ( int Count = 0; Count < sizeof ( EarlySecret.secret ); Count++ )
                                {
                                    fprintf ( DebugFile, " %02x", EarlySecret.secret [ Count ] );
                                }

                                fprintf ( DebugFile, "\n" );
                            }

                            // get any main secret and print it out

                            if ( Component->QuicGetExporter ( 1, &MainSecret ) )
                            {
                                fprintf ( DebugFile,
                                          "MainSecret: Hash = %d (%s), AEAD = %d (%s), Secret =",
                                          MainSecret.hash,
                                          HashNames [ MainSecret.hash ],
                                          MainSecret.ae,
                                          AEADNames [ MainSecret.ae ] );

                                for ( int Count = 0; Count < sizeof ( MainSecret.secret ); Count++ )
                                {
                                    fprintf ( DebugFile, " %02x", MainSecret.secret [ Count ] );
                                }

                                fprintf ( DebugFile, "\n" );
                            }
                         }
                        else
                        {
                            printf ( "Component->ConfigureNamedGroups ( %s ) failed!\n", NamedGroup );
                        }
                    }
                    else
                    {
                        printf ( "Component->ConfigureSignatureAlgorithms ( %s ) failed!\n", SignatureAlgorithm );
                    }
                }
                else
                {
                    printf ( "Component->ConfigureCipherSuites ( %s ) failed!\n", CipherSuite );
                }
            }
            else
            {
                printf ( "Component->Configure() failed!\n" );
            }

            Component->RecordEndTime ();

            if ( VerboseConsoleOutput ) printf ( "Return Code = %d\n", GetLastError () );
        }
        else
        {
            fprintf ( DebugFile, "Cannot connect to peer for test!\n" );

            PrintSocketError ();
        }

        closesocket ( PeerSocket );
    }
    else
    {
        fprintf ( DebugFile, "Cannot open socket for peer!\n" );

        PrintSocketError ();
    }
}

//**********************************************************************************************************************************

void TLSTESTER::RunSingleServerQUICTest ( int         MeasurementNumber,
                                          const char *CipherSuite,
                                          const char *SignatureAlgorithm,
                                          const char *NamedGroup )
{
    fprintf ( DebugFile,
              "Running single server QUIC test %d on Cipher Suite %s, Signature Algorithm %s and Named group %s\n",
              MeasurementNumber,
              CipherSuite,
              SignatureAlgorithm,
              NamedGroup );

    printf ( "Running single server QUIC test %d on Cipher Suite %s, Signature Algorithm %s and Named group %s\n",
             MeasurementNumber,
             CipherSuite,
             SignatureAlgorithm,
             NamedGroup );
}

//**********************************************************************************************************************************

bool TLSTESTER::PrintQuicResult ( quic_result QuicResult ) // old knowledge now hidden!
{
    bool Result = TRUE;

    fprintf ( DebugFile, "QuicResult = %d, ", QuicResult );

    switch ( QuicResult )
    {
        case TLS_would_block :                     fprintf ( DebugFile, "Would block\n"                     ); break;
        case TLS_error_local :                     fprintf ( DebugFile, "Error Local\n"                     ); break;
        case TLS_error_alert :                     fprintf ( DebugFile, "Error Alert\n"                     ); break;
        case TLS_client_early :                    fprintf ( DebugFile, "Client Early\n"                    ); break;
        case TLS_client_complete :                 fprintf ( DebugFile, "Client Complete\n"                 ); break;
        case TLS_client_complete_with_early_data : fprintf ( DebugFile, "Client Complete with Early Data\n" ); break;
        case TLS_server_accept :                   fprintf ( DebugFile, "Server Accept\n"                   ); break;
        case TLS_server_accept_with_early_data :   fprintf ( DebugFile, "Server Accept with Early Data\n"   ); break;
        case TLS_server_complete :                 fprintf ( DebugFile, "Server Complete\n"                 ); break;
        case TLS_server_stateless_retry :          fprintf ( DebugFile, "Server Stateless Retry\n"          ); break;
        case TLS_error_other :                     fprintf ( DebugFile, "Error Other\n"                     ); break;

        default: fprintf ( DebugFile, "Unknown Quic Result\n" ); Result = FALSE; break;
    }

    return (  Result );
}

//**********************************************************************************************************************************

DWORD WINAPI ClientThread ( LPVOID lpParam )
{
    TLSTESTER *Tester = ( TLSTESTER * ) lpParam;

    while ( Tester->TerminateClientThread == FALSE )
    {

    }

    return ( 0 );
}

//**********************************************************************************************************************************

DWORD WINAPI ServerThread ( LPVOID lpParam )
{
    TLSTESTER *Tester = ( TLSTESTER * ) lpParam;

    while ( Tester->TerminateServerThread == FALSE )
    {

    }

    return ( 0 );
}

//**********************************************************************************************************************************

DWORD WINAPI PipeThread ( LPVOID lpParam )
{
    TLSTESTER *Tester = ( TLSTESTER * ) lpParam;

    while ( Tester->TerminatePipeThread == FALSE )
    {

    }

    return ( 0 );
}

//**********************************************************************************************************************************