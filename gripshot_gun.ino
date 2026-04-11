// ... existing code ...
  // Button & output
  static unsigned long lastButtonTime = 0;
  if (digitalRead(BUTTON_PIN) == LOW && (now - lastButtonTime > 300)) {
    lastButtonTime = now;
    Serial.println("Button pressed: Activating solenoid + buzzer + laser");
    
    // Send button press message over BLE
    if (deviceConnected) {
      const char* buttonMsg = "button_pressed";
      pCharacteristic->setValue((uint8_t*)buttonMsg, strlen(buttonMsg));
      pCharacteristic->notify();
      delay(50); // Small delay to ensure message is sent
    }
    
    digitalWrite(SOLENOID_PIN, HIGH);
    digitalWrite(BUZZER_PIN, HIGH);
    digitalWrite(LASER_PIN, HIGH);
    delay(200);
    digitalWrite(SOLENOID_PIN, LOW);
    digitalWrite(BUZZER_PIN, LOW);
    digitalWrite(LASER_PIN, LOW);
  }
// ... existing code ... 