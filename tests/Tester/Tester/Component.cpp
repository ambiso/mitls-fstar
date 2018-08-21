
//**********************************************************************************************************************************
//
//   Purpose: Component, Library and Measurement implementation source code file
//
//   Project: Everest
//
//  Filename: Component.cpp
//
//   Authors: Caroline.M.Mathieson (CMM)
//
//**********************************************************************************************************************************
//
//  Description
//  -----------
//
//! \file Component.cpp
//! \brief Contains the complete implementation of the COMPONENT Object.
//!
//! The COMPONENT object encapsulates two dlls, the "libmitls.dll" which provides the TLS/QUIC handshake, and the "libmipki.dll"
//! which provides certificate handling. The two have to be used in conjunction and they communicate with each other. In fact these
//! two dlls require the presence of the libquiccrypto.dll as well. The performance of each DLL will impact the others, so each must
//! be instrumented and measured. In addition, each DLL uses callbacks and these callbacks must be instrumented and measured as well
//! to measure and eliminate the time spent in the tester code.
//!
//**********************************************************************************************************************************

#include "stdafx.h"
#include "time.h"

#include "Tester.h"

#include "mitlsffi.h" // this is the real interface!
#include "mipki.h"    // interface for the certificate handling

//**********************************************************************************************************************************

 // in SimpleServer.cpp

extern unsigned long DecodePacket ( void *Packet, size_t PacketLength, const char *Title );

extern int PrintSocketError ( void );

extern const char *LookupSignatureAlgorithm ( int   SignatureAlgorithm,
                                              bool *Supported );

//**********************************************************************************************************************************

extern class TLSTESTER *Tester; // to give access to the component instance!!

//**********************************************************************************************************************************

static unsigned int CurrentTestRunNumber = 0; // for use in mipki callbacks which don't have the context

static unsigned int CurrentMeasurementNumber = 0; // for use in mipki callbacks which don't have the context

MEASUREMENTRESULTS *MeasurementResultsArray; // actually indexed by TestRunNumber

//**********************************************************************************************************************************

const char *MeasurementTypeNames [] =  // must be in the same order as the enumerated types
{
    "TLS Client Measurements",       // TLS_CLIENT_MEASUREMENTS,
    "QUIC Client Measurements",      // QUIC_CLIENT_MEASUREMENTS,
    "TLS Server Measurements",       // TLS_SERVER_MEASUREMENTS,
    "QUIC Server Measurements",      // QUIC_SERVER_MEASUREMENTS,
    "OPENSSL Server Measurements",   // OPENSSL_SERVER_MEASUREMENTS,
    "BORINGSSL Server Measurements", // BORINGSSL_SERVER_MEASUREMENTS,
    "MBEDTLS Server Measurements",   // MBEDTLS_SERVER_MEASUREMENTS,
    "WOLFSSL Server Measurements",   // WOLFSSL_SERVER_MEASUREMENTS,
    "FIZZ Server Measurements",      // FIZZ_SERVER_MEASUREMENTS,
    "OPENSSL Client Measurements",   // OPENSSL_CLIENT_MEASUREMENTS,
    "BORINGSSL Client Measurements", // BORINGSSL_CLIENT_MEASUREMENTS,
    "MBEDTLS Client Measurements",   // MBEDTLS_CLIENT_MEASUREMENTS,
    "WOLFSSL Client Measurements",   // WOLFSSL_CLIENT_MEASUREMENTS,
    "FIZZ Client Measurements",      // FIZZ_CLIENT_MEASUREMENTS,
};

const char *FFIMeasurementEntryNames [ MAX_FFI_FUNCTIONS ] = // must be in the same order as the enumerated types
{
    // TLS API functions

    "FFI_mitls_init",                           // FFI_MITLS_INIT,
    "FFI_mitls_configure",                      // FFI_MITLS_CONFIGURE,
    "FFI_mitls_set_ticket_key",                 // FFI_MITLS_SET_TICKET_KEY,
    "FFI_mitls_configure_ticket",               // FFI_MITLS_CONFIGURE_TICKET
    "FFI_mitls_configure_cipher_suites",        // FFI_MITLS_CONFIGURE_CIPHER_SUITES,
    "FFI_mitls_configure_signature_algorithms", // FFI_MITLS_CONFIGURE_SIGNATURE_ALGORITHMS,
    "FFI_mitls_configure_named_groups",         // FFI_MITLS_CONFIGURE_NAMED_GROUPS,
    "FFI_mitls_configure_alpn",                 // FFI_MITLS_CONFIGURE_ALPN,
    "FFI_mitls_configure_early_data",           // FFI_MITLS_CONFIGURE_EARLY_DATA,
    "FFI_mitls_configure_custom_extensions",    // FFI_MITLS_CONFIGURE_CUSTOM_EXTENSIONS
    "FFI_mitls_configure_ticket_callback",      // FFI_MITLS_CONFIGURE_TICKET_CALLBACK,
    "FFI_mitls_configure_nego_callback",        // FFI_MITLS_CONFIGURE_NEGO_CALLBACK
    "FFI_mitls_configure_cert_callbacks",       // FFI_MITLS_CONFIGURE_CERT_CALLBACKS,
    "FFI_mitls_close",                          // FFI_MITLS_CLOSE,
    "FFI_mitls_connect",                        // FFI_MITLS_CONNECT,
    "FFI_mitls_accept_connected",               // FFI_MITLS_ACCEPT_CONNECTED,
    "FFI_mitls_get_exporter",                   // FFI_MITLS_GET_EXPORTER,
    "FFI_mitls_get_cert",                       // FFI_MITLS_GET_CERT,
    "FFI_mitls_send",                           // FFI_MITLS_SEND,
    "FFI_mitls_receive",                        // FFI_MITLS_RECEIVE,
    "FFI_mitls_free",                           // FFI_MITLS_FREE,
    "FFI_mitls_cleanup",                        // FFI_MITLS_CLEANUP,
    "FFI_mitls_set_trace_callback",             // FFI_MITLS_SET_TRACE_CALLBACK,

    // QUIC API functions

    "FFI_mitls_quic_create",           // FFI_MITLS_QUIC_CREATE,
    "FFI_mitls_quic_process",          // FFI_MITLS_QUIC_PROCESS,
    "FFI_mitls_quic_get_exporter",     // FFI_MITLS_QUIC_GET_EXPORTER,
    "FFI_mitls_quic_close",            // FFI_MITLS_QUIC_CLOSE
    "FFI_mitls_get_hello_summary",     // FFI_MITLS_GET_HELLO_SUMMARY,
    "FFI_mitls_find_custom_extension", // FFI_MITLS_FIND_CUSTOM_EXTENSION,
    "FFI_mitls_global_free"            // FFI_MITLS_GLOBAL_FREE,
};

const char *FFICallbackMeasurementEntryNames [ MAX_FFI_CALLBACK_FUNCTIONS ] = // must be in the same order as the enumerated types
{
    // TLS Callback functions

    "FFI_mitls_send_callback",    // FFI_MITLS_SEND_CALLBACK
    "FFI_mitls_receive_callback", // FFI_MITLS_RECEIVE_CALLBACK

    "ffi_mitls_certificate_select_callback", // FFI_MITLS_CERTIFICATE_SELECT_CALLBACK
    "ffi_mitls_certificate_format_callback", // FFI_MITLS_CERTIFICATE_FORMAT_CALLBACK
    "ffi_mitls_certificate_sign_callback",   // FFI_MITLS_CERTIFICATE_SIGN_CALLBACK
    "ffi_mitls_certificate_verify_callback", // FFI_MITLS_CERTIFICATE_VERIFY_CALLBACK

    "ffi_mitls_ticket_callback",      // FFI_MITLS_TICKET_CALLBACK
    "ffi_mitls_negotiation_callback", // FFI_MITLS_NEGOTIATION_CALLBACK
    "ffi_mitls_trace_callback"        // FFI_MITLS_TRACE_CALLBACK
};

const char *PKIMeasurementEntryNames [ MAX_PKI_FUNCTIONS ] = // must be in the same order as the enumerated types
{
    "mipki_init",                  // MIPKI_INIT,
    "mipki_free",                  // MIPKI_FREE,
    "mipki_add_root_file_or_path", // MIPKI_ADD_ROOT_FILE_OR_PATH,
    "mipki_select_certificate",    // MIPKI_SELECT_CERTIFICATE,
    "mipki_sign_verify",           // MIPKI_SIGN_VERFIY,
    "mipki_parse_chain",           // MIPKI_PARSE_CHAIN,
    "mipki_parse_list",            // MIPKI_PARSE_LIST,
    "mipki_format_chain",          // MIPKI_FORMAT_CHAIN,
    "mipki_format_alloc",          // MIPKI_FORMAT_ALLOC,
    "mipki_validate_chain",        // MIPKI_VALIDATE_CHAIN,
    "mipki_free_chain"             // MIPKI_FREE_CHAIN,
};

const char *PKICallbackMeasurementEntryNames [ MAX_PKI_CALLBACK_FUNCTIONS ] = // must be in the same order as the enumerated types
{
    "mipki_password_callback", // MIPKI_PASSWORD_CALLBACK
    "mipki_alloc_callback"     // MIPKI_ALLOC_CALLBACK
};

//**********************************************************************************************************************************
//
// MEASUREMENT Functions
//
//**********************************************************************************************************************************

bool InitialiseMeasurementResults ( void )
{
    COMPONENTMEASUREMENTENTRY *ComponentMeasurementEntry   = NULL;
    CALLBACKMEASUREMENTENTRY  *CallbackMeasurementEntry    = NULL;
    COMPONENTMEASUREMENT      *ComponentMeasurement        = NULL;
    size_t                     MeasurementResultsArraySize = sizeof ( MEASUREMENTRESULTS ) * MAX_MEASUREMENT_TYPES;

    MeasurementResultsArray = ( MEASUREMENTRESULTS * ) malloc ( MeasurementResultsArraySize );

    if ( MeasurementResultsArray != NULL )
    {
        memset ( MeasurementResultsArray, 0, MeasurementResultsArraySize );

        // Initialise the measurement results array

        for ( int TestRunNumber = 0; TestRunNumber < MAX_MEASUREMENT_TYPES; TestRunNumber++ )
        {
            MeasurementResultsArray [ TestRunNumber ].MeasurementTypeName = MeasurementTypeNames [ TestRunNumber ];

            MeasurementResultsArray [ TestRunNumber ].StartTime.QuadPart = 0;
            MeasurementResultsArray [ TestRunNumber ].EndTime.QuadPart   = 0;

            for ( int MeasurementNumber = 0; MeasurementNumber < MAX_MEASUREMENTS; MeasurementNumber++ )
            {
                ComponentMeasurement = &MeasurementResultsArray [ TestRunNumber ].Measurements [ MeasurementNumber ];

                ComponentMeasurement->StartTime.QuadPart = 0;
                ComponentMeasurement->EndTime.QuadPart   = 0;

                for ( int FunctionIndex = 0; FunctionIndex < MAX_FFI_FUNCTIONS; FunctionIndex++ )
                {
                    ComponentMeasurementEntry = &ComponentMeasurement->FFIMeasurements [ FunctionIndex ];

                    ComponentMeasurementEntry->EntryName = FFIMeasurementEntryNames [ FunctionIndex ];

                    ComponentMeasurementEntry->StartTime.QuadPart = 0;
                    ComponentMeasurementEntry->EndTime.QuadPart   = 0;
                }

                for ( int FunctionIndex = 0; FunctionIndex < MAX_PKI_FUNCTIONS; FunctionIndex++ )
                {
                    ComponentMeasurementEntry = &ComponentMeasurement->PKIMeasurements [ FunctionIndex ];

                    ComponentMeasurementEntry->EntryName = PKIMeasurementEntryNames [ FunctionIndex ];

                    ComponentMeasurementEntry->StartTime.QuadPart = 0;
                    ComponentMeasurementEntry->EndTime.QuadPart   = 0;
                }

                for ( int FunctionIndex = 0; FunctionIndex < MAX_FFI_CALLBACK_FUNCTIONS; FunctionIndex++ )
                {
                    CallbackMeasurementEntry = &ComponentMeasurement->FFICallbackMeasurements [ FunctionIndex ];

                    CallbackMeasurementEntry->EntryName = FFICallbackMeasurementEntryNames [ FunctionIndex ];

                    CallbackMeasurementEntry->NumberOfCalls = 0;

                    for ( int CallIndex = 0; CallIndex < MAX_CALLS_PER_MEASUREMENT; CallIndex++ )
                    {
                        CallbackMeasurementEntry->StartTimes [ CallIndex ].QuadPart = 0;
                        CallbackMeasurementEntry->EndTimes   [ CallIndex ].QuadPart = 0;
                    }
                }

                for ( int FunctionIndex = 0; FunctionIndex < MAX_PKI_CALLBACK_FUNCTIONS; FunctionIndex++ )
                {
                    CallbackMeasurementEntry = &ComponentMeasurement->PKICallbackMeasurements [ FunctionIndex ];

                    CallbackMeasurementEntry->EntryName = PKICallbackMeasurementEntryNames [ FunctionIndex ];

                    CallbackMeasurementEntry->NumberOfCalls = 0;

                    for ( int CallIndex = 0; CallIndex < MAX_CALLS_PER_MEASUREMENT; CallIndex++ )
                    {
                        CallbackMeasurementEntry->StartTimes [ CallIndex ].QuadPart = 0;
                        CallbackMeasurementEntry->EndTimes   [ CallIndex ].QuadPart = 0;
                    }
                }
            }
        }

        return ( TRUE );
    }
    else
    {
        printf ( "Cannot allocate memory for measurements array!\n" );
    }

    return ( FALSE );
}

//**********************************************************************************************************************************

bool PrintMeasurementResults ( FILE * MeasurementsResultFile )
{
    COMPONENTMEASUREMENTENTRY *MeasurementEntry          = NULL;
    CALLBACKMEASUREMENTENTRY  *CallbackMeasurementEntry  = NULL;
    COMPONENTMEASUREMENT      *ComponentMeasurement      = NULL;

    // write the measurements to the recorded measurements file

    for ( int TestRunNumber = 0; TestRunNumber < MAX_MEASUREMENT_TYPES; TestRunNumber++ )
    {
        // only print out the test runs which were actually recorded

        if ( MeasurementResultsArray [ TestRunNumber ].StartTime.QuadPart == 0 ) break;

        fprintf ( MeasurementsResultFile, "Measurement Type = %s\n", MeasurementResultsArray [ TestRunNumber ].MeasurementTypeName );

        fprintf ( MeasurementsResultFile, "Measurement StartTime = %I64u\n", MeasurementResultsArray [ TestRunNumber ].StartTime.QuadPart );

        fprintf ( MeasurementsResultFile, "Measurement EndTime = %I64u\n", MeasurementResultsArray [ TestRunNumber ].EndTime.QuadPart );

        for ( int MeasurementNumber = 0; MeasurementNumber < MAX_MEASUREMENTS; MeasurementNumber++ )
        {
            ComponentMeasurement = &MeasurementResultsArray [ TestRunNumber ].Measurements [ MeasurementNumber ];

            // only print out the measurements which were actually recorded

            if ( ComponentMeasurement->StartTime.QuadPart == 0 ) break;

            fprintf ( MeasurementsResultFile, "\nMeasurement Results Entry [ %d ]\n\n", MeasurementNumber );

            fprintf ( MeasurementsResultFile, "Component Test Start Time = %I64u\n", ComponentMeasurement->StartTime.QuadPart );
            fprintf ( MeasurementsResultFile, "Component Test End Time   = %I64u\n", ComponentMeasurement->EndTime.QuadPart   );

            for ( int FunctionIndex = 0; FunctionIndex < MAX_FFI_FUNCTIONS; FunctionIndex++ )
            {
                MeasurementEntry = &ComponentMeasurement->FFIMeasurements [ FunctionIndex ];

                fprintf ( MeasurementsResultFile, " FFI Function Name = %s\n", MeasurementEntry->EntryName );

                fprintf ( MeasurementsResultFile, " Measurement Start Time = %I64u\n", MeasurementEntry->StartTime.QuadPart );
                fprintf ( MeasurementsResultFile, " Measurement End Time   = %I64u\n", MeasurementEntry->EndTime.QuadPart   );
            }

            for ( int FunctionIndex = 0; FunctionIndex < MAX_FFI_CALLBACK_FUNCTIONS; FunctionIndex++ )
            {
                CallbackMeasurementEntry = &ComponentMeasurement->FFICallbackMeasurements [ FunctionIndex ];

                fprintf ( MeasurementsResultFile, " FFI Callback Name = %s\n", CallbackMeasurementEntry->EntryName );

                fprintf ( MeasurementsResultFile, "   Number Of Calls = %u\n", CallbackMeasurementEntry->NumberOfCalls );

                for ( int CallIndex = 0; CallIndex < CallbackMeasurementEntry->NumberOfCalls; CallIndex++ )
                {
                    fprintf ( MeasurementsResultFile, " Measurement Start Time [%03d] = %I64u\n", CallIndex, CallbackMeasurementEntry->StartTimes [ CallIndex ].QuadPart );
                    fprintf ( MeasurementsResultFile, " Measurement End Time   [%03d] = %I64u\n", CallIndex, CallbackMeasurementEntry->EndTimes   [ CallIndex ].QuadPart );
                }
            }

            for ( int FunctionIndex = 0; FunctionIndex < MAX_PKI_FUNCTIONS; FunctionIndex++ )
            {
                MeasurementEntry = &ComponentMeasurement->PKIMeasurements [ FunctionIndex ];

                fprintf ( MeasurementsResultFile, " PKI Function Name = %s\n", MeasurementEntry->EntryName );

                fprintf ( MeasurementsResultFile, " Measurement Start Time = %I64u\n", MeasurementEntry->StartTime.QuadPart );
                fprintf ( MeasurementsResultFile, " Measurement End Time   = %I64u\n", MeasurementEntry->EndTime.QuadPart   );
            }

            for ( int FunctionIndex = 0; FunctionIndex < MAX_PKI_CALLBACK_FUNCTIONS; FunctionIndex++ )
            {
                CallbackMeasurementEntry = &ComponentMeasurement->PKICallbackMeasurements [ FunctionIndex ];

                fprintf ( MeasurementsResultFile, " PKI Callback Name = %s\n", CallbackMeasurementEntry->EntryName );

                fprintf ( MeasurementsResultFile, "   Number Of Calls = %u\n", CallbackMeasurementEntry->NumberOfCalls );

                for ( int CallIndex = 0; CallIndex < CallbackMeasurementEntry->NumberOfCalls; CallIndex++ )
                {
                    fprintf ( MeasurementsResultFile, " Measurement Start Time [%03d] = %I64u\n", CallIndex, CallbackMeasurementEntry->StartTimes [ CallIndex ].QuadPart );
                    fprintf ( MeasurementsResultFile, " Measurement End Time   [%03d] = %I64u\n", CallIndex, CallbackMeasurementEntry->EndTimes   [ CallIndex ].QuadPart );
                }
            }
        }
    }

    return ( TRUE );
}

//**********************************************************************************************************************************

void RecordTestRunStartTime ( void )
{
     QueryPerformanceCounter ( &MeasurementResultsArray [ CurrentTestRunNumber ].StartTime );
}

//**********************************************************************************************************************************

void RecordTestRunEndTime ( void )
{
     QueryPerformanceCounter ( &MeasurementResultsArray [ CurrentTestRunNumber ].EndTime );
}

//**********************************************************************************************************************************
//
// FFI Callback Function wrappers
//
//**********************************************************************************************************************************

void MITLS_CALLCONV TicketCallback ( void               *cb_state,
                                     const char         *sni,
                                     const mitls_ticket *ticket )
{
    CALLBACKMEASUREMENTENTRY *FFICallbackMeasurement = NULL;
    unsigned int              CallCount              = 0;

    FFICallbackMeasurement = &MeasurementResultsArray [ CurrentTestRunNumber ].Measurements [ CurrentMeasurementNumber ].FFICallbackMeasurements [ FFI_MITLS_TICKET_CALLBACK ];

    CallCount = FFICallbackMeasurement->NumberOfCalls++;

    if ( CallCount < MAX_CALLS_PER_MEASUREMENT )
    {
        QueryPerformanceCounter ( &FFICallbackMeasurement->StartTimes [ CallCount ] );
    }

    printf ( "Ticket callback function invoked!\n" );

    if ( CallCount < MAX_CALLS_PER_MEASUREMENT )
    {
        QueryPerformanceCounter ( &FFICallbackMeasurement->EndTimes [ CallCount ] );
    }
}

//**********************************************************************************************************************************

mitls_nego_action MITLS_CALLCONV NegotiationCallback ( void                 *cb_state,
                                                       mitls_version         ver,
                                                       const unsigned char  *exts,
                                                       size_t                exts_len,
                                                       mitls_extension     **custom_exts,
                                                       size_t               *custom_exts_len,
                                                       unsigned char       **cookie,
                                                       size_t               *cookie_len )
{
    CALLBACKMEASUREMENTENTRY *FFICallbackMeasurement = NULL;
    unsigned int              CallCount              = 0;

    FFICallbackMeasurement = &MeasurementResultsArray [ CurrentTestRunNumber ].Measurements [ CurrentMeasurementNumber ].FFICallbackMeasurements [ FFI_MITLS_NEGOTIATION_CALLBACK ];

    CallCount = FFICallbackMeasurement->NumberOfCalls++;

    if ( CallCount < MAX_CALLS_PER_MEASUREMENT )
    {
        QueryPerformanceCounter ( &FFICallbackMeasurement->StartTimes [ CallCount ] );
    }

    printf ( "Negotiation callback function invoked!\n" );

    if ( CallCount < MAX_CALLS_PER_MEASUREMENT )
    {
        QueryPerformanceCounter ( &FFICallbackMeasurement->EndTimes [ CallCount ] );
    }

    return ( TLS_nego_accept );
}

//**********************************************************************************************************************************

void MITLS_CALLCONV TraceCallback ( const char *msg )
{
    printf ( ASES_SET_FOREGROUND_YELLOW );

    printf ( msg );

    printf ( ASES_SET_FOREGROUND_BLACK );
}

//**********************************************************************************************************************************

static unsigned char LargeTransmitBuffer [ 65536 ]; // almost the maximum packet the network will return in one go

static unsigned int LargeTransmitBufferReadIndex = 0;

static unsigned int AmountTransmitted = 0;

static unsigned int ExpectedRecordLength = 0;

static bool IncompleteTransmission = FALSE;

int MITLS_CALLCONV SendCallback ( void                *Context,
                                  const unsigned char *Buffer,
                                  size_t               BufferSize )
{
    size_t                    AmountSent             = 0;
    COMPONENT                *Component              = ( COMPONENT * ) Context;
    CALLBACKMEASUREMENTENTRY *FFICallbackMeasurement = NULL;
    unsigned int              CallCount              = 0;

    FFICallbackMeasurement = &MeasurementResultsArray [ CurrentTestRunNumber ].Measurements [ CurrentMeasurementNumber ].FFICallbackMeasurements [ FFI_MITLS_SEND_CALLBACK ];

    CallCount = FFICallbackMeasurement->NumberOfCalls++;

    if ( CallCount < MAX_CALLS_PER_MEASUREMENT )
    {
        QueryPerformanceCounter ( &FFICallbackMeasurement->StartTimes [ CallCount ] );
    }

    printf ( "Send callback function invoked for %d octets!\n", BufferSize );

    // The component sends the records in sections now (Aug 2018) so we have to send this right away, but keep a copy so that when
    // we have the full record we can decode it.

    AmountSent = send ( Component->Socket, (char * ) Buffer, (int) BufferSize, 0 );

    if ( AmountSent == 0 )
    {
        printf ( "Socket Closed!\n" );
    }
    else
    {
        // append to temporary decoder buffer

        memcpy ( (void *) &LargeTransmitBuffer [ LargeTransmitBufferReadIndex ], (const void *) Buffer, BufferSize );

        LargeTransmitBufferReadIndex += BufferSize;

        AmountTransmitted += BufferSize;

        if ( IncompleteTransmission == FALSE )
        {
            if ( AmountSent == 5 ) // just the header was sent first (API change August 2018)
            {
                // peek into message to get record length if its a TLS handshake record

                TLS_RECORD *TLSRecord = (TLS_RECORD *) Buffer;

                if ( TLSRecord->RecordHeader.ContentType == TLS_CT_HANDSHAKE )
                {
                    ExpectedRecordLength = ( TLSRecord->RecordHeader.ContentLengthHigh * 256 ) + TLSRecord->RecordHeader.ContentLengthLow;

                    IncompleteTransmission = TRUE; // we will need to get the rest before decoding
                }
                else
                {
                    if ( TLSRecord->RecordHeader.ContentType == TLS_CT_ALERT )
                    {
                        DecodePacket ( (void *) LargeTransmitBuffer, BufferSize, "Packet sent to server" );

                        // reset decoder buffer as we know what this is

                        LargeTransmitBufferReadIndex = 0;

                        AmountTransmitted = 0;
                    }
                }
            }
        }
        else
        {
            // do we have enough to decode it yet?

            if ( AmountTransmitted >= ExpectedRecordLength )
            {
                DecodePacket ( (void *) LargeTransmitBuffer, BufferSize, "Packet sent to server" );

                // reset decoder buffer

                LargeTransmitBufferReadIndex = 0;

                AmountTransmitted = 0;

                ExpectedRecordLength = 0;

                IncompleteTransmission = FALSE;
            }
        }
    }

    if ( CallCount < MAX_CALLS_PER_MEASUREMENT )
    {
        QueryPerformanceCounter ( &FFICallbackMeasurement->EndTimes [ CallCount ] );
    }

    return ( (int) AmountSent );
}

//**********************************************************************************************************************************

// PROBLEM: MITLS requests data from the server in sections. It reads the header first and then depending on the fragment length,
//          reads that fragment. However this makes debugging very difficult as the whole record is needed for this. The solution
//          is to read the complete response from the peer and then return it bit by bit as requested by MITLS. So the call back
//          function will read the data from a local buffer rather than from the network buffer.
//

static unsigned char LargeReceiveBuffer [ 65536 ]; // almost the maximum packet the network will return in one go

static unsigned int LargeBufferReadIndex = 0;

static int AmountReceived = 0;

static bool IncompleteTransfer = FALSE;

int MITLS_CALLCONV ReceiveCallback ( void          *Context,
                                     unsigned char *Buffer,
                                     size_t         BufferSize )
{
    size_t                    AmountTransferred      = 0;
    size_t                    AmountRemaining        = 0;
    COMPONENT                *Component              = ( COMPONENT * ) Context;
    CALLBACKMEASUREMENTENTRY *FFICallbackMeasurement = NULL;
    unsigned int              CallCount              = 0;

    FFICallbackMeasurement = &MeasurementResultsArray [ CurrentTestRunNumber ].Measurements [ CurrentMeasurementNumber ].FFICallbackMeasurements [ FFI_MITLS_RECEIVE_CALLBACK ];

    CallCount = FFICallbackMeasurement->NumberOfCalls++;

    printf ( "Receive callback function invoked (with room for %zu octets)!\n", BufferSize );

    if ( CallCount < MAX_CALLS_PER_MEASUREMENT )
    {
        QueryPerformanceCounter ( &FFICallbackMeasurement->StartTimes [ CallCount ] );
    }

    // did the previous call result in an incomplete transfer?

    if ( IncompleteTransfer == FALSE )
    {
        // No, so get as much as the network will provide

        LargeBufferReadIndex = 0;

        AmountReceived = recv ( Component->Socket, (char * ) LargeReceiveBuffer, sizeof ( LargeReceiveBuffer ), 0 );

        if ( AmountReceived > 0 )
        {
            IncompleteTransfer = TRUE;

            // we only decode the packet the first time round!

            DecodePacket ( (void *) LargeReceiveBuffer, AmountReceived, "Packet received from server" );
        }
    }

    // webservers such as bing.com will go mute when you specify a valid but old cipher suite in the clienthello which means that
    // the call to recv() will timeout and an error returned such as "connection reset by peer". So we have to test for this but we
    // also need to indicate back to the component that it has happened, so that it finishes the ffi_mitls_connect() call.

    if ( AmountReceived == -1 )
    {
        PrintSocketError ();

        return ( AmountReceived ); // let libmitls.dll know what has happened
    }

    if ( AmountReceived == 0 )
    {
        printf ( "Socket Closed!\n" );

        IncompleteTransfer = FALSE;
    }
    else
    {
        AmountRemaining = AmountReceived - LargeBufferReadIndex;

        if ( AmountRemaining > BufferSize )
        {
            memcpy ( Buffer, &LargeReceiveBuffer [ LargeBufferReadIndex ], BufferSize );

            AmountTransferred = BufferSize;

            IncompleteTransfer = TRUE; // still more left so still incomplete
        }
        else
        {
            memcpy ( Buffer, &LargeReceiveBuffer [ LargeBufferReadIndex ], AmountRemaining );

            AmountTransferred = AmountRemaining;

            IncompleteTransfer = FALSE; // no more left now so transfer complete
        }

        LargeBufferReadIndex += AmountTransferred;
    }

    if ( CallCount < MAX_CALLS_PER_MEASUREMENT )
    {
        QueryPerformanceCounter ( &FFICallbackMeasurement->EndTimes [ CallCount ] );
    }

    return ( (int) AmountTransferred );
}

//**********************************************************************************************************************************

void *MITLS_CALLCONV CertificateSelectCallback ( void                         *cb_state,
                                                 mitls_version                 ver,
                                                 const unsigned char          *sni,
                                                 size_t                        sni_len,
                                                 const unsigned char          *alpn,
                                                 size_t                        alpn_len,
                                                 const mitls_signature_scheme *sigalgs,
                                                 size_t                        sigalgs_len,
                                                 mitls_signature_scheme       *selected )
{
    CALLBACKMEASUREMENTENTRY *FFICallbackMeasurement = NULL;
    unsigned int              CallCount              = 0;

    FFICallbackMeasurement = &MeasurementResultsArray [ CurrentTestRunNumber ].Measurements [ CurrentMeasurementNumber ].FFICallbackMeasurements [ FFI_MITLS_CERTIFICATE_SELECT_CALLBACK ];

    CallCount = FFICallbackMeasurement->NumberOfCalls++;

    if ( CallCount < MAX_CALLS_PER_MEASUREMENT )
    {
        QueryPerformanceCounter ( &FFICallbackMeasurement->StartTimes [ CallCount ] );
    }

    printf ( "Certificate Select Callback function invoked!\n" );

    if ( CallCount < MAX_CALLS_PER_MEASUREMENT )
    {
        QueryPerformanceCounter ( &FFICallbackMeasurement->EndTimes [ CallCount ] );
    }

    return ( NULL );
}

//**********************************************************************************************************************************

size_t MITLS_CALLCONV CertificateFormatCallback ( void          *cb_state,
                                                  const void    *cert_ptr,
                                                  unsigned char buffer [ MAX_CHAIN_LEN ] )
{
    CALLBACKMEASUREMENTENTRY *FFICallbackMeasurement = NULL;
    unsigned int              CallCount              = 0;

    FFICallbackMeasurement = &MeasurementResultsArray [ CurrentTestRunNumber ].Measurements [ CurrentMeasurementNumber ].FFICallbackMeasurements [ FFI_MITLS_CERTIFICATE_FORMAT_CALLBACK ];

    CallCount = FFICallbackMeasurement->NumberOfCalls++;

    if ( CallCount < MAX_CALLS_PER_MEASUREMENT )
    {
        QueryPerformanceCounter ( &FFICallbackMeasurement->StartTimes [ CallCount ] );
    }

    printf ( "Certificate Format Callback function invoked!\n" );

    if ( CallCount < MAX_CALLS_PER_MEASUREMENT )
    {
        QueryPerformanceCounter ( &FFICallbackMeasurement->EndTimes [ CallCount ] );
    }

    return ( 0 );
}

//**********************************************************************************************************************************

size_t MITLS_CALLCONV CertificateSignCallback ( void                         *cb_state,
                                                const void                   *cert_ptr,
                                                const mitls_signature_scheme  sigalg,
                                                const unsigned char          *tbs,
                                                size_t                        tbs_len,
                                                unsigned char                *sig )
{
    CALLBACKMEASUREMENTENTRY *FFICallbackMeasurement = NULL;
    unsigned int              CallCount              = 0;

    FFICallbackMeasurement = &MeasurementResultsArray [ CurrentTestRunNumber ].Measurements [ CurrentMeasurementNumber ].FFICallbackMeasurements [ FFI_MITLS_CERTIFICATE_SIGN_CALLBACK ];

    CallCount = FFICallbackMeasurement->NumberOfCalls++;

    if ( CallCount < MAX_CALLS_PER_MEASUREMENT )
    {
        QueryPerformanceCounter ( &FFICallbackMeasurement->StartTimes [ CallCount ] );
    }

    printf ( "Certificate Sign Callback function invoked!\n" );

    if ( CallCount < MAX_CALLS_PER_MEASUREMENT )
    {
        QueryPerformanceCounter ( &FFICallbackMeasurement->EndTimes [ CallCount ] );
    }

    return ( 0 );
}

//**********************************************************************************************************************************

// typedef int (MITLS_CALLCONV *pfn_FFI_cert_verify_cb)(void *cb_state,
//const unsigned char* chain,
//size_t chain_len,
//const mitls_signature_scheme sigalg,
//const unsigned char *tbs,
//size_t tbs_len,
//const unsigned char *sig,
//size_t sig_len);

int MITLS_CALLCONV CertificateVerifyCallback ( void                         *State,
                                               const unsigned char          *ChainOfTrust,       // the certificate chain of trust
                                               size_t                        ChainLength,        // how many entries are in the chain
                                               const mitls_signature_scheme  SignatureAlgorithm, // what signature algorithm was used to sign it
                                               const unsigned char          *Certificate,        // the certificate to be verified (tbs)
                                               size_t                        CertificateLength,  // how long it is in octets
                                               const unsigned char          *Signature,          // the signature
                                               size_t                        SignatureLength )   // how long the signature is in octets
{
    CALLBACKMEASUREMENTENTRY *FFICallbackMeasurement  = NULL;
    unsigned int              CallCount               = 0;
    int                       Result                  = 0;
    size_t                    VerifiedSignatureLength = SignatureLength;

    FFICallbackMeasurement = &MeasurementResultsArray [ CurrentTestRunNumber ].Measurements [ CurrentMeasurementNumber ].FFICallbackMeasurements [ FFI_MITLS_CERTIFICATE_VERIFY_CALLBACK ];

    CallCount = FFICallbackMeasurement->NumberOfCalls++;

    if ( CallCount < MAX_CALLS_PER_MEASUREMENT )
    {
        QueryPerformanceCounter ( &FFICallbackMeasurement->StartTimes [ CallCount ] );
    }

    printf ( "Certificate Verify Callback function invoked!\n" );

    bool Supported = FALSE;

    const char *SignatureAlgorithmName = LookupSignatureAlgorithm ( SignatureAlgorithm, &Supported );

    printf ( "             State = 0x%08X\n",     State             );
    printf ( "      ChainOfTrust = 0x%08X\n",     ChainOfTrust      );
    printf ( "       ChainLength = %zd octets\n", ChainLength       );

    printf ( "SignatureAlgorithm = 0x%04X (%s), Supported = %d\n", SignatureAlgorithm, SignatureAlgorithmName, Supported );

    printf ( "       Certificate = 0x%08X\n",     Certificate       );
    printf ( " CertificateLength = %zd octets\n", CertificateLength );
    printf ( "         Signature = 0x%08X\n",     Signature         );
    printf ( "   SignatureLength = %zd octets\n", SignatureLength   );

    // verification requires us to first parse the chain of trust. If all is well, then we use the library to verify the certificate
    // which is why there are so many parameters to this callback

    int ChainNumber = Tester->Component->ParseChain ( (mipki_state *) State, (const char *) ChainOfTrust, ChainLength );

    if ( Tester->Component->CertificateChains [ ChainNumber ] != NULL )
    {
        Result = Tester->Component->ValidateChain ( Tester->Component->CertificateChains [ ChainNumber ] );

        if ( ! Result )
        {
            printf ( "Chain Validation failed!\n" ); // comment on result but otherwise ignore it
        }

         Result = Tester->Component->VerifyCertificate ( (mipki_state *) State,
                                                        Tester->Component->CertificateChains [ ChainNumber ],
                                                        SignatureAlgorithm,
                                                        (const char *) Certificate,
                                                        CertificateLength,
                                                        (char *) Signature,
                                                        &VerifiedSignatureLength );

        if ( ! Result )
        {
            printf ( "Certificate Verification failed!\n" );
        }

        // free the chain as we no longer need it

        Tester->Component->FreeChain ( Tester->Component->CertificateChains [ ChainNumber ] );

        Tester->Component->CertificateChains [ ChainNumber ] = NULL;
    }
    else
    {
        printf ( "Certificate Chain Parsing failed!\n" );
    }

    if ( CallCount < MAX_CALLS_PER_MEASUREMENT )
    {
        QueryPerformanceCounter ( &FFICallbackMeasurement->EndTimes [ CallCount ] );
    }

    return ( Result );
}

//**********************************************************************************************************************************
//
// PKI Callback Function wrappers
//
//**********************************************************************************************************************************

int MITLS_CALLCONV CertificatePasswordCallback ( char       *password,
                                                 int         max_size,
                                                 const char *key_file )
{
    CALLBACKMEASUREMENTENTRY *PKICallbackMeasurement = NULL;
    unsigned int              CallCount              = 0;

    PKICallbackMeasurement = &MeasurementResultsArray [ CurrentTestRunNumber ].Measurements [ CurrentMeasurementNumber ].PKICallbackMeasurements [ MIPKI_PASSWORD_CALLBACK ];

    CallCount = PKICallbackMeasurement->NumberOfCalls++;

    if ( CallCount < MAX_CALLS_PER_MEASUREMENT )
    {
        QueryPerformanceCounter ( &PKICallbackMeasurement->StartTimes [ CallCount ] );
    }

    printf ( "Certificate Password Callback function invoked!\n" );

    if ( CallCount < MAX_CALLS_PER_MEASUREMENT )
    {
        QueryPerformanceCounter ( &PKICallbackMeasurement->EndTimes [ CallCount ] );
    }

    return ( 0 );
}

//**********************************************************************************************************************************

void *MITLS_CALLCONV CertificateAllocationCallback ( void    *cur,
                                                     size_t   len,
                                                     char   **buf )
{
    CALLBACKMEASUREMENTENTRY *PKICallbackMeasurement = NULL;
    unsigned int              CallCount              = 0;

    PKICallbackMeasurement = &MeasurementResultsArray [ CurrentTestRunNumber ].Measurements [ CurrentMeasurementNumber ].PKICallbackMeasurements [ MIPKI_ALLOC_CALLBACK ];

    CallCount = PKICallbackMeasurement->NumberOfCalls++;

    if ( CallCount < MAX_CALLS_PER_MEASUREMENT )
    {
        QueryPerformanceCounter ( &PKICallbackMeasurement->StartTimes [ CallCount ] );
    }

    printf ( "Certificate Allocation Callback function invoked!\n" );

    if ( CallCount < MAX_CALLS_PER_MEASUREMENT )
    {
        QueryPerformanceCounter ( &PKICallbackMeasurement->EndTimes [ CallCount ] );
    }

    return ( NULL );
}

//**********************************************************************************************************************************
//
// COMPONENT Methods
//
//**********************************************************************************************************************************

COMPONENT::COMPONENT ( FILE *TestResultsFile )
{
    DebugFile = TestResultsFile;

    TestRunNumber = 0;

    MeasurementNumber = 0;

    CurrentTestRunNumber = 0;

    CurrentMeasurementNumber = 0;

    CurrentComponentMeasurement = &MeasurementResultsArray [ 0 ].Measurements [ 0 ];

    if ( ! InitialiseMeasurementResults () )
    {
        printf ( "No measurements can be made, this is fatal!\n" );

        exit ( EXIT_FAILURE ); // this is fatal so exit
    }
}

//**********************************************************************************************************************************

COMPONENT::~COMPONENT ( void )
{
}

//**********************************************************************************************************************************

void COMPONENT::SetTestRunNumber ( int NewTestRunNumber )
{
    TestRunNumber = NewTestRunNumber;

    CurrentTestRunNumber = TestRunNumber;

    // when we change the test run number, the measurements should start at 0 again

    SetMeasurementNumber ( 0 );
}

//**********************************************************************************************************************************

void COMPONENT::SetMeasurementNumber ( int NewMeasurementNumber )
{
    MeasurementNumber = NewMeasurementNumber;

    CurrentMeasurementNumber = MeasurementNumber;

    CurrentComponentMeasurement = &MeasurementResultsArray [ TestRunNumber ].Measurements [ MeasurementNumber ];
}

//**********************************************************************************************************************************

void COMPONENT::SetSocket ( SOCKET ServerSocket )
{
    Socket = ServerSocket;
}

//**********************************************************************************************************************************

void COMPONENT::SetNumberOfMeasurementsMade ( int FinalNumberOfMeasurementsMade )
{
    NumberOfMeasurementsMade = FinalNumberOfMeasurementsMade;
}

//**********************************************************************************************************************************

void COMPONENT::RecordStartTime ( void )
{
    QueryPerformanceCounter ( &MeasurementResultsArray [ TestRunNumber ].Measurements [ MeasurementNumber ].StartTime );
}

//**********************************************************************************************************************************

void COMPONENT::RecordEndTime ( void )
{
    QueryPerformanceCounter ( &MeasurementResultsArray [ TestRunNumber ].Measurements [ MeasurementNumber ].EndTime );
}

//**********************************************************************************************************************************

char *COMPONENT::GetHostName ( void )
{
    return ( (char *) HostName );
}

//**********************************************************************************************************************************

int COMPONENT::GetPortNumber ( void )
{
    return ( PortNumber );
}

//**********************************************************************************************************************************
//
// TLS API Function wrappers
//
//**********************************************************************************************************************************

int COMPONENT::InitialiseTLS ( void )
{
    fprintf ( DebugFile, "FFI_mitls_init () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_INIT ].StartTime );

    int Result = FFI_mitls_init ();

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_INIT ].EndTime );

    return ( Result );
}

//**********************************************************************************************************************************

int COMPONENT::Configure ( void )
{
    fprintf ( DebugFile, "FFI_mitls_configure () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CONFIGURE ].StartTime );

    int Result = FFI_mitls_configure ( &TLSState, TLSVersion, HostName ); // note that this one requires a state double pointer!

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CONFIGURE ].EndTime );

    return ( Result );
}

//**********************************************************************************************************************************

int COMPONENT::SetTicketKey ( const char          *Algorithm,
                              const unsigned char *TicketKey,
                              size_t               TicketKeyLength )
{
    fprintf ( DebugFile, "FFI_mitls_set_ticket_key () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_SET_TICKET_KEY ].StartTime );

    int Result = FFI_mitls_set_ticket_key ( Algorithm, TicketKey, TicketKeyLength ); // const char *alg, const unsigned char *ticketkey, size_t klen)

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_SET_TICKET_KEY ].EndTime );

    return ( Result );
}

//**********************************************************************************************************************************

int COMPONENT::ConfigureCipherSuites ( const char *CipherSuites )
{
    fprintf ( DebugFile, "FFI_mitls_configure_cipher_suites () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CONFIGURE_CIPHER_SUITES ].StartTime );

    int Result = FFI_mitls_configure_cipher_suites ( TLSState, CipherSuites );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CONFIGURE_CIPHER_SUITES ].EndTime );

    return ( Result );
}

//**********************************************************************************************************************************

int COMPONENT::ConfigureSignatureAlgorithms ( const char *SignatureAlgorithms )
{
    fprintf ( DebugFile, "FFI_mitls_configure_signature_algorithms () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CONFIGURE_SIGNATURE_ALGORITHMS ].StartTime );

    int Result = FFI_mitls_configure_signature_algorithms ( TLSState, SignatureAlgorithms );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CONFIGURE_SIGNATURE_ALGORITHMS ].EndTime );

    return ( Result );
}

//**********************************************************************************************************************************

int COMPONENT::ConfigureNamedGroups ( const char *NamedGroups )
{
    fprintf ( DebugFile, "FFI_mitls_configure_named_groups () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CONFIGURE_NAMED_GROUPS ].StartTime );

    int Result = FFI_mitls_configure_named_groups ( TLSState, NamedGroups );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CONFIGURE_NAMED_GROUPS ].EndTime );

    return ( Result );
}

//**********************************************************************************************************************************

int COMPONENT::ConfigureApplicationLayerProtocolNegotiation ( const char *ApplicationLayerProtocolNegotiation )
{
    fprintf ( DebugFile, "FFI_mitls_configure_alpn () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CONFIGURE_ALPN ].StartTime );

    int Result = FFI_mitls_configure_alpn ( TLSState, ApplicationLayerProtocolNegotiation );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CONFIGURE_ALPN ].EndTime );

    return ( Result );
}

//**********************************************************************************************************************************

int COMPONENT::ConfigureEarlyData ( uint32_t MaximumEarlyData )
{
    fprintf ( DebugFile, "FFI_mitls_configure_early_data () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CONFIGURE_EARLY_DATA ].StartTime );

    int Result = FFI_mitls_configure_early_data ( TLSState, MaximumEarlyData );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CONFIGURE_EARLY_DATA ].EndTime );

    return ( Result );
}

//**********************************************************************************************************************************

void COMPONENT::ConfigureTraceCallback ( void )
{
    fprintf ( DebugFile, "FFI_mitls_set_trace_callback () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_SET_TRACE_CALLBACK ].StartTime );

    FFI_mitls_set_trace_callback ( TraceCallback );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_SET_TRACE_CALLBACK ].EndTime );
}
//**********************************************************************************************************************************

int COMPONENT::ConfigureTicketCallback ( void              *CallbackState,
                                         pfn_FFI_ticket_cb  TicketCallback )
{
    fprintf ( DebugFile, "FFI_mitls_configure_ticket_callback () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CONFIGURE_TICKET_CALLBACK ].StartTime );

    int Result = FFI_mitls_configure_ticket_callback ( TLSState, CallbackState, TicketCallback );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CONFIGURE_TICKET_CALLBACK ].EndTime );

    return ( Result );
}

//**********************************************************************************************************************************

int COMPONENT::ConfigureNegotiationCallback ( void )
{
    fprintf ( DebugFile, "FFI_mitls_configure_nego_callback () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CONFIGURE_NEGO_CALLBACK ].StartTime );

    int Result = FFI_mitls_configure_nego_callback ( TLSState, NULL, NegotiationCallback );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CONFIGURE_NEGO_CALLBACK ].EndTime );

    return ( Result );
}

//**********************************************************************************************************************************

int COMPONENT::ConfigureCertificateCallbacks ( void )
{
    mitls_cert_cb CertificateCallbacks;

    // setup the callback functions structure with the wrapper functions (so we can do measurements)

    CertificateCallbacks.format = CertificateFormatCallback;
    CertificateCallbacks.select = CertificateSelectCallback;
    CertificateCallbacks.sign   = CertificateSignCallback;
    CertificateCallbacks.verify = CertificateVerifyCallback;

    fprintf ( DebugFile, "FFI_mitls_configure_cert_callbacks () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CONFIGURE_CERT_CALLBACKS ].StartTime );

    int Result = FFI_mitls_configure_cert_callbacks ( TLSState, PKIState, &CertificateCallbacks );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CONFIGURE_CERT_CALLBACKS ].EndTime );

    return ( Result );
}

//**********************************************************************************************************************************

void COMPONENT::CloseConnection ( void )
{
    fprintf ( DebugFile, "FFI_mitls_close () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CLOSE ].StartTime );

    FFI_mitls_close ( TLSState );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CLOSE ].EndTime );
}

//**********************************************************************************************************************************

int COMPONENT::Connect ( void )
{
    fprintf ( DebugFile, "FFI_mitls_connect () called\n" );

    CurrentMeasurementNumber = MeasurementNumber; // record the measurement number used for the connect call for use in callbacks

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CONNECT ].StartTime );

    int Result = FFI_mitls_connect ( ( void * ) this, SendCallback, ReceiveCallback, TLSState );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CONNECT ].EndTime );

    return ( Result );
}

//**********************************************************************************************************************************

int COMPONENT::AcceptConnected ( void  )
{
    fprintf ( DebugFile, "FFI_mitls_accept_connected () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_ACCEPT_CONNECTED ].StartTime );

    int Result = FFI_mitls_accept_connected ( ( void * ) this, SendCallback, ReceiveCallback, TLSState  );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_ACCEPT_CONNECTED ].EndTime );

    return ( Result );
}

//**********************************************************************************************************************************

int COMPONENT::GetExporter ( int           early,
                             mitls_secret *secret )
{
    fprintf ( DebugFile, "FFI_mitls_get_exporter () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_GET_EXPORTER ].StartTime );

    int Result = FFI_mitls_get_exporter ( TLSState, early, secret );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_GET_EXPORTER ].EndTime );

    return ( Result );
}

//**********************************************************************************************************************************

void *COMPONENT::GetCertificate ( size_t *cert_size )
{
    fprintf ( DebugFile, "FFI_mitls_get_cert () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_GET_CERT ].StartTime );

    void *Certificate = FFI_mitls_get_cert ( TLSState, cert_size );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_GET_CERT ].EndTime );

    return ( Certificate );
}

//**********************************************************************************************************************************

int COMPONENT::Send ( const unsigned char *buffer,
                      size_t               buffer_size )
{
    fprintf ( DebugFile, "FFI_mitls_send () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_SEND ].StartTime );

    int Result = FFI_mitls_send ( TLSState, buffer, buffer_size );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_SEND ].EndTime );

    return ( Result );
}

//**********************************************************************************************************************************

void *COMPONENT::Receive ( size_t *packet_size )
{
    fprintf ( DebugFile, "FFI_mitls_receive () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_RECEIVE ].StartTime );

    void *Packet = FFI_mitls_receive ( TLSState, packet_size );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_RECEIVE ].EndTime );

    return ( Packet );
}

//**********************************************************************************************************************************

void COMPONENT::Cleanup ( void )
{
    fprintf ( DebugFile, "FFI_mitls_cleanup () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CLEANUP ].StartTime );

    FFI_mitls_cleanup ();

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_CLEANUP ].EndTime );
}

//**********************************************************************************************************************************
//
// QUIC API Function wrappers
//
//**********************************************************************************************************************************

mitls_cert_cb CertificateCallbacks =
{
    CertificateCallbacks.select = CertificateSelectCallback,
    CertificateCallbacks.format = CertificateFormatCallback,
    CertificateCallbacks.sign   = CertificateSignCallback,
    CertificateCallbacks.verify = CertificateVerifyCallback,
};

mitls_extension QuicClientTransportParameters =
{
    QuicClientTransportParameters.ext_type     = (uint16_t) 0x1A, // TLS_ET_QUIC_TRANSPORT_PARAMETERS
    QuicClientTransportParameters.ext_data     = (const unsigned char*) "\xff\xff\x00\x05\x0a\x0b\x0c\x0d\x0e\x00",
    QuicClientTransportParameters.ext_data_len = 9,
};

int COMPONENT::QuicCreate ( void )
{
    fprintf ( DebugFile, "FFI_mitls_quic_create () called\n" );

    // set the right configuration for this test

    Configuration.callback_state = &QUICState;
    Configuration.cert_callbacks = &CertificateCallbacks;
    Configuration.nego_callback  = &NegotiationCallback;

    Configuration.exts       = &QuicClientTransportParameters;
    Configuration.exts_count = 1;

    // and call the API with this config

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_QUIC_CREATE ].StartTime );

    int Result = FFI_mitls_quic_create ( &QUICState, &Configuration );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_QUIC_CREATE ].EndTime );

    return ( Result );
}

//**********************************************************************************************************************************

quic_result COMPONENT::QuicProcess ( const unsigned char *inBuf,
                                     size_t              *pInBufLen,
                                     unsigned char       *outBuf,
                                     size_t              *pOutBufLen )
{
    fprintf ( DebugFile, "FFI_mitls_quic_process () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_QUIC_PROCESS ].StartTime );

    quic_result Result = FFI_mitls_quic_process ( QUICState, inBuf, pInBufLen, outBuf, pOutBufLen );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_QUIC_PROCESS ].EndTime );

    return ( Result );
}

//**********************************************************************************************************************************

int COMPONENT::QuicGetExporter ( int          early,
                                 quic_secret *secret )
{
    fprintf ( DebugFile, "FFI_mitls_quic_get_exporter () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_QUIC_GET_EXPORTER ].StartTime );

    //int Result = FFI_mitls_quic_get_exporter ( QUICState, early, secret );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_QUIC_GET_EXPORTER ].EndTime );

    return ( 0 /*Result*/ );
}

//**********************************************************************************************************************************

void COMPONENT::QuicClose ( void )
{
    fprintf ( DebugFile, "FFI_mitls_quic_close () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_QUIC_CLOSE ].StartTime );

    //FFI_mitls_quic_close ( QUICState );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_QUIC_CLOSE ].EndTime );
}

//**********************************************************************************************************************************

int COMPONENT::GetHelloSummary ( const unsigned char  *buffer,
                                 size_t                buffer_len,
                                 mitls_hello_summary  *summary,
                                 unsigned char       **cookie,
                                 size_t               *cookie_len )
{
    fprintf ( DebugFile, "FFI_mitls_quic_get_hello_summary () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_GET_HELLO_SUMMARY ].StartTime );

    int Result = FFI_mitls_get_hello_summary ( buffer, buffer_len, summary, cookie, cookie_len );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_GET_HELLO_SUMMARY ].EndTime );

    return ( Result );
}

//**********************************************************************************************************************************

int COMPONENT::FindCustomExtension ( int                   is_server,
                                     const unsigned char  *exts,
                                     size_t                exts_len,
                                     uint16_t              ext_type,
                                     unsigned char       **ext_data,
                                     size_t               *ext_data_len )
{
    fprintf ( DebugFile, "FFI_mitls_find_custom_extension () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_FIND_CUSTOM_EXTENSION ].StartTime );

    int Result = FFI_mitls_find_custom_extension ( is_server, exts, exts_len, ext_type, ext_data, ext_data_len );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_FIND_CUSTOM_EXTENSION ].EndTime );

    return ( Result );
}

//**********************************************************************************************************************************

void COMPONENT::GlobalFree ( void *pv )
{
    fprintf ( DebugFile, "FFI_mitls_global_free () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_GLOBAL_FREE ].StartTime );

    FFI_mitls_global_free ( pv );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->FFIMeasurements [ FFI_MITLS_GLOBAL_FREE ].EndTime );
}

//**********************************************************************************************************************************
//
// PKI API Function wrappers
//
//**********************************************************************************************************************************

int COMPONENT::InitialisePKI ( void )
{
    signed int         ErrorIndex;
    mipki_config_entry Configuration [ 1 ];

    Configuration [ 0 ].cert_file    = ServerCertificateFilename; // only 1 certificate and key
    Configuration [ 0 ].key_file     = ServerCertificateKeyFilename;
    Configuration [ 0 ].is_universal = TRUE;

    fprintf ( DebugFile, "mipki_init () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_INIT ].StartTime );

    PKIState = mipki_init ( Configuration, 1, NULL, &ErrorIndex );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_INIT ].EndTime );

    return ( ErrorIndex );
}

//**********************************************************************************************************************************

void COMPONENT::TerminatePKI ( void )
{
    fprintf ( DebugFile, "mipki_free () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_FREE ].StartTime );

    mipki_free ( PKIState );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_FREE ].EndTime );
}

//**********************************************************************************************************************************

int COMPONENT::AddRootFileOrPath ( const char *CertificateAuthorityFile )
{
    fprintf ( DebugFile, "mipki_add_root_file_or_path () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_ADD_ROOT_FILE_OR_PATH ].StartTime );

    int Result = mipki_add_root_file_or_path ( PKIState, CertificateAuthorityFile );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_ADD_ROOT_FILE_OR_PATH ].EndTime );

    return ( Result );
}

//**********************************************************************************************************************************

mipki_chain COMPONENT::SelectCertificate ( void )
{
    fprintf ( DebugFile, "mipki_select_certificate () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_SELECT_CERTIFICATE ].StartTime );

    // mipki_chain Chain = mipki_select_certificate ( PKIState, const char *sni, size_t sni_len, const mipki_signature *algs, size_t algs_len, mipki_signature *selected );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_SELECT_CERTIFICATE ].EndTime );

    return ( NULL );
}

//**********************************************************************************************************************************

int COMPONENT::SignCertificate ( mipki_chain CertificatePointer )
{
    fprintf ( DebugFile, "mipki_sign_verify () called in Sign Mode\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_SIGN_VERFIY ].StartTime );

    // int Result = mipki_sign_verify ( PKIState, CertificatePointer, const mipki_signature sigalg, const char *tbs, size_t tbs_len, char *sig, size_t *sig_len, MIPKI_SIGN );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_SIGN_VERFIY ].EndTime );

    return ( 0 );
}

//**********************************************************************************************************************************

// extern "C" int MITLS_CALLCONV mipki_sign_verify(mipki_state *st,
// mipki_chain cert_ptr,
// const mipki_signature sigalg,
// const char *tbs,
// size_t tbs_len,
// char *sig,
// size_t *sig_len,
// mipki_mode m);

int COMPONENT::VerifyCertificate ( mipki_state           *State,               // use the state provided by the callback!
                                   mipki_chain            CertificatePointer,
                                   const mipki_signature  SignatureAlgorithm,
                                   const char            *Certificate,
                                   size_t                 CertificateLength,
                                   char                  *Signature,
                                   size_t                *SignatureLength )
{
    fprintf ( DebugFile, "mipki_sign_verify () called in Verify Mode\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_SIGN_VERFIY ].StartTime );

    int Result = mipki_sign_verify ( State,
                                     CertificatePointer,
                                     SignatureAlgorithm,
                                     Certificate,
                                     CertificateLength,
                                     Signature,
                                     SignatureLength,
                                     MIPKI_VERIFY );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_SIGN_VERFIY ].EndTime );

    return ( Result );
}

//**********************************************************************************************************************************

int COMPONENT::ParseChain ( mipki_state *State,        // use the state provided by the callback!
                            const char  *ChainOfTrust, // the certificate chain of trust in TLS network format
                            size_t       ChainLength ) // returns index into CertificateChains []
{
    fprintf ( DebugFile, "mipki_parse_chain () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_PARSE_CHAIN ].StartTime );

    if ( NumberOfChainsAllocated < MAX_CERTIFICATE_CHAINS )
    {
        // keep a record of the chains parsed and the parsed chain

        CertificateChains [ NumberOfChainsAllocated ] = mipki_parse_chain ( State, ChainOfTrust, ChainLength );
    }
    else
    {
        printf ( "Number of certificate chains in component exceeded!\n" );
    }

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_PARSE_CHAIN ].EndTime );

    return ( NumberOfChainsAllocated++ );
}

//**********************************************************************************************************************************

mipki_chain COMPONENT::ParseList ( void )
{
    fprintf ( DebugFile, "mipki_parse_list () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_PARSE_LIST ].StartTime );

    // mipki_chain Chain = mipki_parse_list ( PKIState, const char **certs, const size_t* certs_len, size_t chain_len );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_PARSE_LIST ].EndTime );

    return ( NULL );
}

//**********************************************************************************************************************************

int COMPONENT::FormatChain ( mipki_chain Chain )
{
    fprintf ( DebugFile, "mipki_format_chain () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_FORMAT_CHAIN ].StartTime );

    // size_t Result = mipki_format_chain ( PKIState, Chain, char *buffer, size_t buffer_len );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_FORMAT_CHAIN ].EndTime );

    return ( 0 );
}

//**********************************************************************************************************************************

void COMPONENT::FormatAllocation ( mipki_chain Chain )
{
    fprintf ( DebugFile, "mipki_format_alloc () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_FORMAT_ALLOC ].StartTime );

    // mipki_format_alloc ( PKIState, Chain, void* init, alloc_callback cb );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_FORMAT_ALLOC ].EndTime );
}

//**********************************************************************************************************************************

int COMPONENT::ValidateChain ( mipki_chain Chain )
{
    fprintf ( DebugFile, "mipki_validate_chain () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_VALIDATE_CHAIN ].StartTime );

    int Result = mipki_validate_chain ( PKIState, Chain, "" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_VALIDATE_CHAIN ].EndTime );

    return ( Result );
}

//**********************************************************************************************************************************

void COMPONENT::FreeChain ( mipki_chain Chain )
{
    fprintf ( DebugFile, "mipki_free_chain () called\n" );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_FREE_CHAIN ].StartTime );

    mipki_free_chain ( PKIState, Chain );

    QueryPerformanceCounter ( &CurrentComponentMeasurement->PKIMeasurements [ MIPKI_FREE_CHAIN ].EndTime );
}

//**********************************************************************************************************************************