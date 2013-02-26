
/**

311 Agent Status Microcontroller

This is a simple webservice that triggers an LED based on the
webservice variable that is received.

http://X.X.X.X/?r - Red LED PIN7 (AUX State)
http://X.X.X.X/?w - White LED PIN9 Other)
http://X.X.X.X/?b - Blue LED PIN8 (EXTOUT)
http://X.X.X.X/?y - Yellow LED PIN5  (EXTIN)
http://X.X.X.X/?g - Green LED PIN6 (Available State)
http://X.X.X.X/?o - All LEDs off




**/

#include <Ethernet.h>
#include <SPI.h>
boolean reading = false;

////////////////////////////////////////////////////////////////////////
//CONFIGURE
////////////////////////////////////////////////////////////////////////
  //byte ip[] = { 192, 168, 0, 199 };   //Manual setup only
  //byte gateway[] = { 192, 168, 0, 1 }; //Manual setup only
  //byte subnet[] = { 255, 255, 255, 0 }; //Manual setup only

  // if need to change the MAC address (Very Rare)
  byte mac[] = { 0xDE, 0xAD, 0xBE, 0xEF, 0xFE, 0xED };

  EthernetServer server = EthernetServer(80); //port 80
////////////////////////////////////////////////////////////////////////

void setup(){
  Serial.begin(9600);

  //Pins 10,11,12 & 13 are used by the ethernet shield

  pinMode(5, OUTPUT);
  pinMode(6, OUTPUT);
  pinMode(7, OUTPUT);
  pinMode(8, OUTPUT);
  pinMode(9, OUTPUT);

  Ethernet.begin(mac);
  //Ethernet.begin(mac, ip, gateway, subnet); //for manual setup

  server.begin();
  Serial.println(Ethernet.localIP());

}

void loop(){

  // listen for incoming clients, and process qequest.
  checkForClient();

}

void checkForClient(){

  EthernetClient client = server.available();

  if (client) {

    // an http request ends with a blank line
    boolean currentLineIsBlank = true;
    boolean sentHeader = false;

    while (client.connected()) {
      if (client.available()) {

        if(!sentHeader){
          // send a standard http response header
          client.println("HTTP/1.1 200 OK");
          client.println("Content-Type: text/html");
          client.println();
          sentHeader = true;
        }

        char c = client.read();

        if(reading && c == ' ') reading = false;
        if(c == '?') reading = true; //found the ?, begin reading the info

        if(reading){
          Serial.print(c);

           if (c == 'w') { 
              triggerPin9(9, client);
          } else if (c == 'b'){
            triggerPin8(8, client);
          } else if (c == 'r'){
            triggerPin7(7, client);
          } else if (c == 'g'){
           triggerPin6(6, client); 
          } else if (c == 'y'){
            triggerPin5(5, client);
          }else if (c == 'o'){
            AllPinsoff(client);
          }

        }

        if (c == '\n' && currentLineIsBlank)  break;

        if (c == '\n') {
          currentLineIsBlank = true;
        }else if (c != '\r') {
          currentLineIsBlank = false;
        }

      }
    }

    delay(1); // give the web browser time to receive the data
    client.stop(); // close the connection:

  } 

}

void triggerPin9(int pin, EthernetClient client){
//blink a pin - Client needed just for HTML output purposes.  
  client.print("White LED is on ");
  client.println(pin);
  client.print("<br>");

  digitalWrite(pin, HIGH);
  digitalWrite(5, LOW);
  digitalWrite(6, LOW);
  digitalWrite(7, LOW);
  digitalWrite(8, LOW);
  ;
}

void triggerPin8(int pin, EthernetClient client){
//blink a pin - Client needed just for HTML output purposes.  
  client.print("Blue LED is on pin ");
  client.println(pin);
  client.print("<br>");

  digitalWrite(pin, HIGH);
  digitalWrite(5, LOW);
  digitalWrite(6, LOW);
  digitalWrite(7, LOW);
  digitalWrite(9, LOW);
  ;
}

void triggerPin7(int pin, EthernetClient client){
//blink a pin - Client needed just for HTML output purposes.  
  client.print("Red LED is on pin ");
  client.println(pin);
  client.print("<br>");

  digitalWrite(pin, HIGH);
  digitalWrite(5, LOW);
  digitalWrite(6, LOW);
  digitalWrite(8, LOW);
  digitalWrite(9, LOW);
  ;
}

void triggerPin6(int pin, EthernetClient client){
//blink a pin - Client needed just for HTML output purposes.  
  client.print("Green LED is on pin ");
  client.println(pin);
  client.print("<br>");

  digitalWrite(pin, HIGH);
  digitalWrite(5, LOW);
  digitalWrite(7, LOW);
  digitalWrite(8, LOW);
  digitalWrite(9, LOW);
  ;
}

void triggerPin5(int pin, EthernetClient client){
//blink a pin - Client needed just for HTML output purposes.  
  client.print("Yellow LED is on pin ");
  client.println(pin);
  client.print("<br>");

  digitalWrite(pin, HIGH);
  digitalWrite(6, LOW);
  digitalWrite(7, LOW);
  digitalWrite(8, LOW);
  digitalWrite(9, LOW);
  ;
}

void AllPinsoff(EthernetClient client){
//blink a pin - Client needed just for HTML output purposes.  
  client.print("All LEDs are off ");
  client.print("\n");

  digitalWrite(5, LOW);
  digitalWrite(6, LOW);
  digitalWrite(7, LOW);
  digitalWrite(8, LOW);
  digitalWrite(9, LOW);
  ;
}
