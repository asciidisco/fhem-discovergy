#   70_DISCOVERGY.pm
#   An FHEM Perl module ses the DISCOVERGY API to read the 
#   current power consumption of DISCOVERGY smart meters

package main;

use strict;
use warnings;
use POSIX;
use JSON;
use Data::Dumper;

sub DISCOVERGY_Initialize($);
sub DISCOVERGY_Define($$);
sub DISCOVERGY_Undefine($$);
sub DISCOVERGY_Set($@);
sub DISCOVERGY_Get($@);
sub DISCOVERGY_GetUpdate($);
sub DISCOVERGY_Attr(@);
sub DISCOVERGY_HandleDataCallback($$$);

my $modulVersion = "2016-11-23";

sub DISCOVERGY_Initialize($) {
  my ($hash) = @_;
  
  $hash->{DefFn} = "DISCOVERGY_Define";
  $hash->{UndefFn} = "DISCOVERGY_Undefine";
  $hash->{SetFn} = "DISCOVERGY_Set";
  $hash->{GetFn} = "DISCOVERGY_Get";
  $hash->{AttrFn} = "DISCOVERGY_Attr";
  
  $hash->{AttrList} = "disable:1,0 ".
                      "granularReadings:1,0 ".
                      "interval ".
                      $readingFnAttributes;
}

sub DISCOVERGY_Define($$) {
  my ($hash, $def) = @_;
  my @args = split("[ \t][ \t]*", $def);
  my $test = substr $args[2], 0, 10;
  
  return "Usage: define <name> DISCOVERGY <meterID> <user> <password> <interval:180-900>" if (@args != 6);
  return "$test seems not to be a valid Discovergy-MeterID. <MeterID> should start with 'EASYMETER_'" if ($test ne "EASYMETER_");
  return "invalid Value for <interval>, please specify a value between 180 and 900" if (int($args[5]) < 180 || int($args[5]) > 900);
  
  my $name = $args[0];
  my $meterID = $args[2];
  my $user = $args[3];
  my $password = $args[4];
  my $interval = $args[5];
  
  # module internals
  $hash->{NAME} = $name;
  $hash->{NOTIFYDEV} = "global";
  $hash->{interval} = $interval;
  $hash->{meterID} = $meterID;
  $hash->{user} = $user;
  $hash->{password} = $password;
  $hash->{LOCAL} = 0;
  $hash->{helper}{rawJSON} = "";  
    
  # FHEM internals
  $hash->{fhem}{modulVersion} = $modulVersion;
  Log3 $hash, 5, "$name: 70_DISCOVERGY.pm version is $modulVersion.";
  
  # start polling
  if ($init_done) {
    readingsBeginUpdate($hash);
    # at first, we delete old readings. They most likely changed anyways
    CommandDeleteReading(undef, "$hash->{NAME} (M|m)easurement_.*");
    CommandDeleteReading(undef, "$hash->{NAME} error");
    CommandDeleteReading(undef, "$hash->{NAME} power"); 
    CommandDeleteReading(undef, "$hash->{NAME} count");
    # set status 
    readingsBulkUpdate($hash, "state", "active", 1) if (!IsDisabled($name));
    readingsBulkUpdate($hash, "state", "inactive", 1) if (IsDisabled($name));
    # set module states (connection & API)
    readingsBulkUpdate($hash, "connection", "initialising", 1);
    readingsBulkUpdate($hash, "api_status", "initialising", 1);   
    # remove timers
    RemoveInternalTimer($hash, "DISCOVERGY_GetUpdate");
    # start fetching
    DISCOVERGY_GetUpdate($hash) if (!IsDisabled($name));
    readingsEndUpdate($hash, $hash->{LOCAL});
  }  
  
  return undef;
}

sub DISCOVERGY_Undefine($$) {
  my ($hash, $arg) = @_;
  # remove all the timers
  RemoveInternalTimer($hash, "DISCOVERGY_GetUpdate");
  RemoveInternalTimer($hash, "HttpUtils_NonblockingGet");
  return undef;                
}

sub DISCOVERGY_Attr(@) {
  my ($cmd, $name, $attrName, $attrValue) = @_;
  
  if ($attrName eq "interval") {
    if (int($attrValue) < 180 || int($attrValue) > 900) {
      return "interval must be an integer with a value between 180 & 900";
    }
  } elsif ($attrName eq "granularReadings") {
    if (int($attrValue) != 1 && int($attrValue) != 0) {
      return "granularReadings must be a binary value represented by integers 0 or 1";
    }
  } elsif ($attrName eq "disable") {
    if (int($attrValue) != 1 && int($attrValue) != 0) {
      return "disable must be a binary value represented by integers 0 or 1";
    }
  } 
  
  return undef;     
}

sub DISCOVERGY_Set($@) {
  my ($hash, @a) = @_;
  my $name = $hash->{NAME};
  my $cmd = $a[1];
  my $val = $a[2];
  my $resultStr = "";
  
  # trigger manual API fetch
  if($cmd eq 'update') {
    $hash->{LOCAL} = 1;
    DISCOVERGY_GetUpdate($hash);
    return undef;
  # set polling interval
  } elsif ($cmd eq "interval" && int(@_) == 4) {
    $val = 180 if ($val < 180);
    $val = 900 if ($val < 900);
    $hash->{interval} = $val;
    return "$name: Polling interval set to $val seconds.";
  # turn granular readings on/off
  } elsif ($cmd eq "granularReadings") {
    readingsSingleUpdate($hash, "granularReadings", $val, 1);
    return "$name: granular readings set to".$val;
  # enable/disable the module
  } elsif ($cmd eq "disable") {
    readingsSingleUpdate($hash, "state", "active", 1) if ($val eq 0);
    readingsSingleUpdate($hash, "state", "inactive", 1) if ($val eq 1);
    return "$name: disabled ".$val;
  }
  
  # possible values
  my $list = "disable:1,0 ".
             "granularReadings:1,0 ".  
             "update:noArg ".
             "interval:slider,180,900,90";
        
  return "Unknown argument $cmd, choose one of $list";
}

sub DISCOVERGY_Get($$@) {
  my ( $hash, $name, $opt, @args ) = @_;
  return "\"get $name\" needs at least one argument" unless(defined($opt));
 
  if ($opt eq "state") {
    return ReadingsVal($name, "state", undef);
  } elsif($opt eq "power") {
    return ReadingsVal($name, "power", 0);
  } elsif($opt eq "granularReadings") {
    return ReadingsVal($name, "granularReadings", 0);
  } elsif($opt eq "error") {
    return ReadingsVal($name, "error", "");  
  } elsif($opt eq "connection") {
    return ReadingsVal($name, "connection", "");
  } elsif($opt eq "api_status") {
    return ReadingsVal($name, "api_status", "");
  } elsif($opt eq "count") {
    return ReadingsVal($name, "count", 0);
  } elsif($opt eq "rawJSON") {
    return $hash->{helper}{rawJSON};
  }
  
  # possible values
  my $list = "state:noArg ".
             "power:noArg ".
             "granularReadings:noArg ".
             "error:noArg ".
             "connection:noArg ".
             "api_status:noArg ".
             "count:noArg ".
             "rawJSON:noArg"; 
  
  return "Unknown argument $opt choose one of $list";
}

sub DISCOVERGY_GetUpdate($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $param;
  
  # update internal module state
  readingsSingleUpdate($hash, "connection", "initialising", 1);
  readingsSingleUpdate($hash, "api_status", "initialising", 1);
    
  Log3 $name, 5, "Discovergy ($name): Requesting POST: https://my.discovergy.com/json/Api.getLive";
  
  # using POST & HTTPS for max security
  $param = {
    url => "https://my.discovergy.com/json/Api.getLive",
    method => "POST",
    data => {
      "user" => $hash->{user},
      "password" => $hash->{password},
      "meterId" => $hash->{meterID},
      "numOfSeconds" => $hash->{interval},
    },
    timeout => 7,
    wType => "fetch",   
    header => {
      "Content-Type" => "application/x-www-form-urlencoded",
    },
    hash => $hash,
    callback => \&DISCOVERGY_HandleDataCallback,
  };
  
  InternalTimer(gettimeofday()+1, "HttpUtils_NonblockingGet", $param, 0); 
  return undef;          
}

sub DISCOVERGY_HandleDataCallback($$$){
  my ($param, $err, $data) = @_;
  
  my $hash = $param->{hash};
  my $name = $hash->{NAME};
  my $granularReadings = ReadingsVal($name, "granularReadings", 0);
  
  readingsBeginUpdate($hash);
  # check if the connection itself 
  if ($err ne "") {
      Log3 $name, 5, "error while requesting ".$param->{url}." - $err";
      readingsBulkUpdate($hash, "error", $err);
      readingsBulkUpdate($hash, "connection", "error");
      readingsBulkUpdate($hash, "api_status", "unknown");
  } elsif($data ne "") {
      Log3 $name, 3, "url ".$param->{url}." returned: $data";
      my $decoded_json = decode_json($data);
      $hash->{helper}{rawJSON} = $data;

      # check if the API returned an error (connection succeeded, but the API threw an error)
      if ($decoded_json->{status} eq "error") {
        Log3 $name, 5, "error while requesting ".$param->{url}." - ".$decoded_json->{reason};
        readingsBulkUpdate($hash, "error", $decoded_json->{reason});
        readingsBulkUpdate($hash, "connection", "connected");
        readingsBulkUpdate($hash, "api_status", "error");
        
      # check if the API request was successfull
      } elsif($decoded_json->{status} eq "ok") {
        
        # update the status hash as everything regarding the connection went fine
        readingsBulkUpdate($hash, "connection", "connected");
        readingsBulkUpdate($hash, "api_status", "online");
        
        my @measurements = @{$decoded_json->{result}};
        my $i = 0;
        my @powerMeasurements = ();
        Log3 $name, 5, "Callback data (decoded JSON): ".Dumper($decoded_json);
        
        # iterate over the decoded json (measurements contain 2 values power & time)
        foreach my $measurement (@measurements) {
          my $t = sprintf('%03d', $i);
          # convert power to watt for avg calculation (power is the drawn power in 10^-3 W)
          push @powerMeasurements, $measurement->{power}*0.001;
          # log the raw power reading with incremental numbers (force no update-event for those readings)
          # if the user has set the attribute `granularReadings` (power is the drawn power in 10^-3 W)
          readingsBulkUpdate($hash, "measurement_".$t, (ceil($measurement->{power}*0.001 * 100) / 100)." W", 0) if ($granularReadings == 1);
          $i++;
        }
        readingsBulkUpdate($hash, "error", "none");
        readingsBulkUpdate($hash, "count", $i);
        
        # calculate the avg reading for the interval
        my $sum = 0;
        $sum += $_ for @powerMeasurements;
        readingsBulkUpdate($hash, "power", (ceil($sum/$i * 100) / 100)." W");
        readingsBulkUpdate($hash, "state", (ceil($sum/$i * 100) / 100)." W", 1) if (!IsDisabled($name));
      }
  }
  
  readingsEndUpdate($hash, $hash->{LOCAL});
  
  # loop with Interval
  RemoveInternalTimer($hash, "DISCOVERGY_GetUpdate");
  InternalTimer(gettimeofday()+$hash->{interval}, "DISCOVERGY_GetUpdate", $hash, 0);
  
  # reset the manual fetch state variable (just in case a statusRequest has been issued)
  $hash->{LOCAL} = 0;
}

1;

=pod
=item summary    Uses the DISCOVERGY API to read the current power consumption of DISCOVERGY smart meters
=item summary_DE Ermittelt den aktuellen Stromverbrauch eines DISCOVERGY Stromzählers via des DISCOVERGY APIs
=begin html

<a name="DISCOVERGY"></a>
<h3>DISCOVERGY</h3>
<ul>
  A module to get the current power consumption of DISCOVERGY smart meters.
  
  The module ist based on the Api Hash version: BA2BCE37587262A56CAAC2208A96B40C
  The API documentationen can be accessed here: https://my.discovergy.com/json/Api/help
  It actually only uses the "/json/Api.getLive" method from the API to fetch the current power consumption.
  
  This module needs the Perl modules JSON and Data::Dumper in order to get it to work.
  <br /><br />
  <a name="DISCOVERGY_Define"></a>
  <b>Define</b><br />
  <ul>
    <code>define &lt;name&gt; DISCOVERGY &lt;meterID&gt; &lt;user&gt; &lt;password&gt; &lt;interval&gt;</code><br />
    <br />
    <b>meterID:</b> To obtain this ID, you need to load this URL into your browser: https://my.discovergy.com/json/Api.getMeters?user=%user%&password=%user%<br />
    <b>user:</b> This is your MyDiscovergy user (usually your mail address)<br />
    <b>password:</b> This is your MyDiscovergy password<br />
    <b>interval:</b> Interval to fetch data from the API in ms (should be between 180-900)<br />
    <br /><br />

    Example:
    <ul>
      <code>define MyPowermeter DISCOVERGY EASYMETER_12345678 my@mail.com myPassword 180</code><br />
    </ul>
  </ul><br />
  <br />
  <a name="DISCOVERGY_Set"></a>
  <b>Set</b>
  <ul>
    <li><b>disabled</b> - set the device active/inactive (measurements will be polled/timers will be deleted, polling is off))</li><br />
    <li><b>interval</b> - set the pollInterval in seconds</li><br />
    <li><b>update</b> - force a manual measurement update</li><br />
    <li><b>granularReadings</b> - activate/deactivate savings of all readings in 5sec intervals </li><br />   
  </ul>
  
  <a name="DISCOVERGY_Attributes"></a>
  <b>Attributes</b><br />
  <ul>
    <li>disable</li>
    module is disabled (e.g. polling is off)
    <li>interval</li>
    get the list every pollInterval seconds. Smallest possible value is 180, highest 900.<br /><br />
    <li>granularReadings</li>
    store all the readings in 5sec intervals (tunred off by default)<br /><br />
    <li>rawJSON</li>
    raw response of the last API call<br /><br />       
  </ul><br />
  
  <a name="DISCOVERGY_Readings"></a>
  <b>Readings</b><br />
  <ul>
    <li>measurement_X<br />
      if the granularReadings setting is active, measurements are listet as measurement_0, measurement_1 [...]. (Usually DISCOVERGY takes a measurement every 5 seconds)</li><br />
    <li>count<br />
      number of measurements taken during the last call.</li><br />
    <li>power<br />
      average consumption of all measurements taken during the last call.</li><br />  
    <li>error<br />
      error message if an error occured during the last API call (Connection or API error)</li><br />
    <li>api_status<br />
      status of the api connection</li><br />
    <li>connection<br />
      status of the http connection</li><br />                  
  </ul><br />
</ul>

=end html
=cut