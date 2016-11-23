# fhem-discovergy

A module to get the current power consumption of DISCOVERGY smart meters in FHEM. 

The module ist based on the Api Hash version: **BA2BCE37587262A56CAAC2208A96B40C** 

The API documentationen can be accessed here: https://my.discovergy.com/json/Api/help 
It actually only uses the "/json/Api.getLive" method from the API to fetch the current power consumption. 

This module needs the Perl modules JSON and Data::Dumper in order to get it to work. 

```
define <name> DISCOVERGY <meterID> <user> <password> <interval>
```

- *meterID*: To obtain this ID, you need to load this URL into your browser: [https://my.discovergy.com/json/Api.getMeters?user=%user%&password=%password%](https://my.discovergy.com/json/Api.getMeters?user=%user%&password=%password%)
- *user*: This is your MyDiscovergy user (usually your mail address)
- *password*: This is your MyDiscovergy password
- *interval*: Interval to fetch data from the API in ms (should be between 180-900)


### Example:
```
define MyPowermeter DISCOVERGY EASYMETER_12345678 my@mail.com myPassword 180
```

####Set
- *disabled*: set the device active/inactive (measurements will be polled/timers will be deleted, polling is off))
- *interval*: set the pollInterval in seconds
- *update*: force a manual measurement update
- *granularReadings*: activate/deactivate savings of all readings in 5sec intervals

####Attributes
- *disable*: Module is disabled/enabled
- *interval*: get the list every pollInterval seconds. Smallest possible value is 180, highest 900.
- *granularReadings*: store all the readings in 5sec intervals (tunred off by default)
- *rawJSON*: raw response of the last API call


####Readings
- *measurement_X*: if the granularReadings setting is active, measurements are listet as measurement_0, measurement_1 [...]. (Usually DISCOVERGY takes a measurement every 5 seconds)
- *count*: number of measurements taken during the last call.
- *power*: average consumption of all measurements taken during the last call.
- *error*: error message if an error occured during the last API call (Connection or API error)
- *api_status*: status of the api connection
- *connection*: status of the http connection

### Installation:
```
update all https://raw.githubusercontent.com/asciidisco/fhem-discovergy/master/DISCOVERGY.txt
```